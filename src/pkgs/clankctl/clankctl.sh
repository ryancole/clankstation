# clankctl: Clankstation admin CLI for the OS phase (design: section 5.8).
#
# Expects these variables, set by the Nix wrapper (src/pkgs/clankctl/default.nix):
#   CLANK_DATA        data root, e.g. /var/lib/clankstation
#   CLANK_UID/GID     uid/gid of the clankstation user and the container agent
#   CLANK_IMAGE       default Linux task image
#   CLANK_TASK_RUN    in-container task runner script (store path)
#
# Harness rule: clankctl never reads, copies or prints harness credentials.
# Sign-in happens inside the container through the vendor's own flow, and
# the harness stores its token in the user's home volume.

CLANK_USER="${CLANK_USER:-default}"

usage() {
  cat <<'EOF'
Usage: clankctl <command> [args]

Projects:
  project add <name> <git-url>   Mirror a git repository onto the box
  project list                   List projects

Tasks:
  run <project> <prompt>         Start a headless task (prompt "-" reads stdin)
  status                         List tasks and their state
  show <task-id>                 Prompt, state, summary and diffstat of a task
  diff <task-id>                 The task's diff against its base commit

Harness (per-user, opt-in):
  harness enable claude          Install Claude Code into your home volume (official installer)
  harness status                 Show installed harnesses and whether you are signed in
  login claude                   Sign in to Claude Code (vendor's own sign-in flow)

Environments:
  shell [cmd...]                 Open a shell (or run cmd) in the default Linux image
                                 with your home volume mounted

Environment variables:
  CLANK_USER                     Household user whose home volume to use (default: default)
EOF
}

die() {
  echo "clankctl: $*" >&2
  exit 1
}

# Run as the clankstation service user, so files get the right owner.
if [ "$(id -u)" != "$CLANK_UID" ]; then
  exec sudo --preserve-env=CLANK_USER,TERM -u "#$CLANK_UID" -- "$0" "$@"
fi

valid_name() {
  case "$1" in
    "" | [!a-z0-9]* | *[!a-z0-9_-]*) return 1 ;;
  esac
}

valid_name "$CLANK_USER" || die "CLANK_USER must be lowercase letters, digits, - or _"

home_volume="$CLANK_DATA/users/$CLANK_USER/home"
projects="$CLANK_DATA/projects"
tasks="$CLANK_DATA/tasks"

# Read key=value files without sourcing them.
kv() {
  sed -n "s/^$2=//p" "$1" | head -n 1
}

ensure_home_volume() {
  if [ ! -d "$home_volume" ]; then
    mkdir -p "$home_volume"
    chmod 0700 "$home_volume"
  fi
}

require_image() {
  docker image inspect "$CLANK_IMAGE" >/dev/null 2>&1 ||
    die "image $CLANK_IMAGE is not built yet (see: systemctl status clankstation-image-linux-default)"
}

# Options shared by every container: run as agent, with the home volume.
container_opts() {
  printf '%s\n' \
    --user "$CLANK_UID:$CLANK_GID" \
    --env HOME=/home/agent \
    --env PATH=/home/agent/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    --volume "$home_volume:/home/agent"
}

# docker run in the default image, as agent, with the home volume mounted.
# Usage: env_run [docker-run-options...] -- command [args...]
env_run() {
  ensure_home_volume
  require_image
  local opts=()
  while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do
    opts+=("$1")
    shift
  done
  [ "$#" -gt 0 ] && shift
  local tty=(-i)
  if [ -t 0 ] && [ -t 1 ]; then
    tty+=(-t)
  fi
  local common
  mapfile -t common < <(container_opts)
  docker run --rm "${tty[@]}" "${common[@]}" --workdir /home/agent "${opts[@]}" \
    "$CLANK_IMAGE" "$@"
}

# First use of a home volume: copy the image's shell dotfiles in. No stdin
# attached, so it can't eat input meant for the command that follows.
init_home() {
  env_run --interactive=false --tty=false -- sh -c 'cp -rn /etc/skel/. "$HOME"/ 2>/dev/null || true'
}

# ---- harness -----------------------------------------------------------------

cmd_harness() {
  case "${1:-}" in
    enable)
      [ "${2:-}" = claude ] || die "usage: clankctl harness enable claude"
      init_home
      echo "Installing Claude Code with the official installer (https://claude.ai/install.sh)..."
      env_run -- bash -c 'curl -fsSL https://claude.ai/install.sh | bash'
      ;;
    status)
      init_home
      env_run -- sh -c '
        if command -v claude >/dev/null 2>&1; then
          echo "claude: $(claude --version)"
          claude auth status || true
        else
          echo "claude: not installed (run: clankctl harness enable claude)"
        fi'
      ;;
    *) die "usage: clankctl harness enable claude | clankctl harness status" ;;
  esac
}

cmd_login() {
  [ "${1:-}" = claude ] || die "usage: clankctl login claude"
  env_run -- sh -c 'command -v claude >/dev/null 2>&1' ||
    die "Claude Code is not installed (run: clankctl harness enable claude)"
  env_run -- claude auth login
}

cmd_shell() {
  init_home
  if [ "$#" -eq 0 ]; then
    env_run -- bash -l
  else
    env_run -- "$@"
  fi
}

# ---- projects ----------------------------------------------------------------

cmd_project() {
  case "${1:-}" in
    add)
      local name="${2:-}" url="${3:-}"
      [ -n "$name" ] && [ -n "$url" ] || die "usage: clankctl project add <name> <git-url>"
      valid_name "$name" || die "project names are lowercase letters, digits, - or _"
      local dir="$projects/$name"
      [ -e "$dir" ] && die "project $name already exists"
      mkdir -p "$dir"
      if ! git clone --quiet --mirror "$url" "$dir/mirror.git"; then
        rm -rf "$dir"
        die "could not clone $url"
      fi
      printf 'url=%s\ntemplate=linux-default\n' "$url" >"$dir/project.env"
      echo "Added project $name ($(git -C "$dir/mirror.git" symbolic-ref --short HEAD))"
      ;;
    list)
      local d
      for d in "$projects"/*/; do
        [ -f "$d/project.env" ] || continue
        printf '%-20s %s\n' "$(basename "$d")" "$(kv "$d/project.env" url)"
      done
      ;;
    *) die "usage: clankctl project add <name> <git-url> | clankctl project list" ;;
  esac
}

# ---- tasks -------------------------------------------------------------------

new_task_id() {
  printf 't-%s-%s' "$(date -u +%Y%m%d-%H%M%S)" "$(od -An -N2 -tx1 /dev/urandom | tr -d ' \n')"
}

task_dir() {
  case "$1" in
    t-[0-9]*-[0-9]*-[0-9a-f]*) ;;
    *) die "not a task id: $1" ;;
  esac
  [ -d "$tasks/$1" ] || die "no such task: $1"
  printf '%s' "$tasks/$1"
}

task_state() {
  local id="$1" t="$tasks/$1"
  if [ "$(docker inspect -f '{{.State.Running}}' "clank-$id" 2>/dev/null)" = true ]; then
    echo running
  elif [ -f "$t/status.json" ]; then
    jq -r .state "$t/status.json"
  else
    echo lost
  fi
}

# Start the task container. Detached and owned by dockerd, so it keeps
# running after the SSH session (and clankctl) exit.
start_task() {
  local id="$1" t="$tasks/$1" common
  mapfile -t common < <(container_opts)
  docker run --detach --rm \
    --name "clank-$id" \
    --label "clankstation.task=$id" \
    --label "clankstation.project=$(kv "$t/task.env" project)" \
    "${common[@]}" \
    --volume "$t:/clank" \
    --volume "$t/worktree:/workspace" \
    --volume "$CLANK_TASK_RUN:/opt/clankstation/task-run:ro" \
    --workdir /workspace \
    "$CLANK_IMAGE" bash /opt/clankstation/task-run >/dev/null
}

cmd_run() {
  local name="${1:-}" prompt="${2:-}"
  [ -n "$name" ] && [ -n "$prompt" ] || die "usage: clankctl run <project> <prompt>"
  valid_name "$name" || die "not a project name: $name"
  local dir="$projects/$name" mirror="$projects/$name/mirror.git"
  [ -d "$mirror" ] || die "no such project: $name (see: clankctl project list)"
  if [ "$prompt" = - ]; then prompt=$(cat); fi
  # The native installer makes this a symlink to an absolute path inside the
  # container (/home/agent/...), which doesn't resolve on the host; check the
  # link itself.
  local claude_bin="$home_volume/.local/bin/claude"
  [ -L "$claude_bin" ] || [ -x "$claude_bin" ] ||
    die "Claude Code is not installed (run: clankctl harness enable claude)"
  require_image

  git -C "$mirror" remote update --prune >/dev/null 2>&1 ||
    echo "clankctl: warning: could not fetch $name; using the copy on the box" >&2
  local branch base id t
  branch=$(git -C "$mirror" symbolic-ref --short HEAD)
  base=$(git -C "$mirror" rev-parse "refs/heads/$branch")
  id=$(new_task_id)
  t="$tasks/$id"

  mkdir -p "$t"
  printf '%s\n' "$prompt" >"$t/prompt.txt"
  printf '%s\n' "$base" >"$t/base"
  printf 'project=%s\nbranch=%s\nbase=%s\ncreated=%s\nuser=%s\n' \
    "$name" "$branch" "$base" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$CLANK_USER" >"$t/task.env"

  # A local clone (hardlinked objects, so cheap) keeps the task's repo
  # self-contained; the agent can't damage the mirror.
  git clone --quiet --branch "$branch" "$mirror" "$t/worktree"
  git -C "$t/worktree" remote set-url origin "$(kv "$dir/project.env" url)"
  git -C "$t/worktree" switch --quiet --create "clank/$id"

  start_task "$id"
  echo "$id"
  echo "Started. Check on it with: clankctl status   (or: clankctl show $id)" >&2
}

cmd_status() {
  local d id
  printf '%-27s %-8s %-16s %s\n' TASK STATE PROJECT PROMPT
  for d in "$tasks"/t-*/; do
    [ -f "$d/task.env" ] || continue
    id=$(basename "$d")
    printf '%-27s %-8s %-16s %s\n' "$id" "$(task_state "$id")" \
      "$(kv "$d/task.env" project)" "$(head -n 1 "$d/prompt.txt" | cut -c1-60)"
  done
}

cmd_show() {
  local id="${1:-}" t state
  [ -n "$id" ] || die "usage: clankctl show <task-id>"
  t=$(task_dir "$id")
  state=$(task_state "$id")
  echo "Task:    $id"
  echo "Project: $(kv "$t/task.env" project) ($(kv "$t/task.env" branch) @ $(kv "$t/task.env" base | cut -c1-12))"
  echo "Created: $(kv "$t/task.env" created)"
  echo "State:   $state"
  if [ -f "$t/status.json" ]; then
    echo "Session: $(jq -r .session_id "$t/status.json")"
  fi
  echo
  echo "Prompt:"
  sed 's/^/  /' "$t/prompt.txt"
  if [ "$state" != running ] && [ -f "$t/result/summary.md" ]; then
    echo
    echo "Summary:"
    sed 's/^/  /' "$t/result/summary.md"
    echo
    echo "Changes:"
    if [ -s "$t/result/diffstat.txt" ]; then sed 's/^/  /' "$t/result/diffstat.txt"; else echo "  (none)"; fi
  fi
}

cmd_diff() {
  local id="${1:-}" t
  [ -n "$id" ] || die "usage: clankctl diff <task-id>"
  t=$(task_dir "$id")
  if [ "$(task_state "$id")" = running ]; then
    echo "# task is still running; showing tracked changes so far" >&2
    git -C "$t/worktree" diff "$(cat "$t/base")"
  else
    cat "$t/result/diff.patch"
  fi
}

case "${1:-}" in
  harness) shift; cmd_harness "$@" ;;
  login) shift; cmd_login "$@" ;;
  shell) shift; cmd_shell "$@" ;;
  project) shift; cmd_project "$@" ;;
  run) shift; cmd_run "$@" ;;
  status) shift; cmd_status "$@" ;;
  show) shift; cmd_show "$@" ;;
  diff) shift; cmd_diff "$@" ;;
  -h | --help | help | "") usage ;;
  *) usage >&2; exit 1 ;;
esac
