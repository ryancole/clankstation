# clankctl: Clankstation admin CLI for the OS phase (design: section 5.8).
#
# Expects these variables, set by the Nix wrapper (src/pkgs/clankctl/default.nix):
#   CLANK_DATA        data root, e.g. /var/lib/clankstation
#   CLANK_UID/GID     uid/gid of the clankstation user and the container agent
#   CLANK_IMAGE       default Linux task image
#   CLANK_TASK_RUN    in-container task runner script (store path)
#   CLANK_BASH        bash from the Nix store, used to start the runner
#   CLANK_AGENT_LAYER build context for the agent layer on devcontainer images
#   CLANK_WINDOWS_TEMPLATES  Autounattend.xml, setup.ps1, build-domain.xml
#   CLANK_VIRTIO_WIN  virtio-win drivers and guest tools (unpacked)
#
# Harness rule: clankctl never reads, copies or prints harness credentials.
# Sign-in happens inside the container through the vendor's own flow, and
# the harness stores its token in the user's home volume.

CLANK_USER="${CLANK_USER:-default}"

usage() {
  cat <<'EOF'
Usage: clankctl <command> [args]

Projects:
  project add [--template auto|linux-default] <name> <git-url>
                                 Mirror a git repository onto the box. With "auto"
                                 (the default), a repo with a devcontainer.json runs
                                 in its own devcontainer; otherwise the default image
  project list                   List projects

Tasks:
  run <project> <prompt>         Start a headless task (prompt "-" reads stdin); it
                                 waits in line when the box is busy
  status                         List tasks and their state
  show <task-id>                 Prompt, state, summary and diffstat of a task
  diff <task-id>                 The task's diff against its base commit
  logs <task-id> [-f]            What the agent did (-f: follow a running task)
  resume <task-id> <prompt>      Keep going: a new headless turn in the same session
  attach [--yes] <task-id>       Take over in an interactive Claude Code terminal
                                 (a running task's headless run is stopped first)
  stop <task-id>                 Stop a running task (keeps its results so far),
                                 or take a waiting one out of the line
  queue                          Tasks waiting in line, oldest first
  clean [--older-than 7d] [--dry-run]
                                 Remove the worktrees of tasks that finished longer
                                 ago than that (a daily timer does this with 7d),
                                 and devcontainer images no remaining task uses.
                                 Summaries, diffs and logs are kept
  delete <task-id>               Remove a finished task entirely, results included

Harness (per-user, opt-in):
  harness enable claude          Install Claude Code into your home volume (official installer)
  harness status                 Show installed harnesses and whether you are signed in
  login claude                   Sign in to Claude Code (vendor's own sign-in flow)

Environments:
  shell [cmd...]                 Open a shell (or run cmd) in the default Linux image
                                 with your home volume mounted
  shell --task <task-id> [cmd...]
                                 The same, inside a task's environment (its running
                                 container, or a new one on its worktree)

Windows base images (QEMU/KVM):
  windows build-base <name> --iso <file> [--edition NAME] [--key KEY]
                     [--disk SIZE] [--memory MIB] [--cpus N] [--no-build-tools]
                                 Install Windows unattended from an ISO and keep the
                                 result as a read-only base image (takes ~1 hour)
  windows list                   Base images and builds in progress
  windows log <name> [-f]        Setup progress of a build
  windows screenshot <name> <file.png>
                                 The build VM's screen (updated every 20 s)
  windows cancel <name>          Stop a build
  windows remove <name>          Delete a base image (or a failed build)

System:
  config                         Show settings
  config set max-running <n>     How many tasks run at once (default 1); others
                                 wait in line and start on their own
  update [--check]               Update the box from its flake on GitHub (--check:
                                 only show the installed and latest revisions)

Environment variables:
  CLANK_USER                     Household user whose home volume to use (default: default)
EOF
}

die() {
  echo "clankctl: $*" >&2
  exit 1
}

# Update the system from the flake this box was installed from (design: 5.2).
# Runs as the calling admin (sudo for the rebuild), not the service user.
cmd_update() {
  local check=false
  case "${1:-}" in
    --check) check=true ;;
    "") ;;
    *) die "usage: clankctl update [--check]" ;;
  esac
  local env=/etc/clankstation/update.env flake config current latest
  flake=$(sed -n 's/^flake=//p' "$env" 2>/dev/null || true)
  config=$(sed -n 's/^configuration=//p' "$env" 2>/dev/null || true)
  [ -n "$flake" ] && [ -n "$config" ] ||
    die "updates are off on this system (the dev VM is rebuilt from the repo in WSL instead)"
  current=$(nixos-version --configuration-revision 2>/dev/null || true)
  latest=$(nix flake metadata --refresh --json "$flake" | jq -r '.revision // empty') ||
    die "could not reach $flake"
  echo "Installed: ${current:-unknown} ($config)"
  echo "Latest:    ${latest:-unknown} ($flake)"
  if [ -n "$latest" ] && [ "$current" = "$latest" ]; then
    echo "Up to date."
    return 0
  fi
  [ "$check" = false ] || return 0
  local sudo=(sudo)
  if [ "$(id -u)" = 0 ]; then sudo=(); fi
  "${sudo[@]}" nixos-rebuild switch --refresh --flake "$flake#$config"
  echo "Now at: $(nixos-version --configuration-revision 2>/dev/null || echo unknown)"
  if [ "$(readlink -f /run/booted-system/kernel)" != "$(readlink -f /run/current-system/kernel)" ]; then
    echo "The kernel changed: reboot to use it (sudo reboot)."
  fi
}

if [ "${1:-}" = update ]; then
  shift
  cmd_update "$@"
  exit
fi

# Run as the clankstation service user, so files get the right owner.
if [ "$(id -u)" != "$CLANK_UID" ]; then
  exec sudo --preserve-env=CLANK_USER,CLANK_WINDOWS_DRY_RUN,TERM -u "#$CLANK_UID" -- "$0" "$@"
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
  local image="${1:-$CLANK_IMAGE}"
  docker image inspect "$image" >/dev/null 2>&1 || {
    if [ "$image" = "$CLANK_IMAGE" ]; then
      die "image $image is not built yet (see: systemctl status clankstation-image-linux-default)"
    fi
    die "image $image is missing"
  }
}

# The image's own PATH, with the home volume's ~/.local/bin (harness
# installs) in front.
agent_path_for() {
  local path
  path=$(docker image inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$1" |
    sed -n 's/^PATH=//p' | head -n 1)
  printf '/home/agent/.local/bin:%s' "${path:-/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin}"
}

# Options shared by every container: run as agent, with the home volume.
# Usage: container_opts [image]
container_opts() {
  printf '%s\n' \
    --user "$CLANK_UID:$CLANK_GID" \
    --env HOME=/home/agent \
    --env "PATH=$(agent_path_for "${1:-$CLANK_IMAGE}")" \
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
  if [ "${1:-}" = --task ]; then
    shift
    task_shell "$@"
    return
  fi
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
      shift
      local template=auto
      if [ "${1:-}" = --template ]; then
        template="${2:-}"
        shift 2 || true
      fi
      case "$template" in auto | linux-default) ;; *) die "templates: auto, linux-default" ;; esac
      local name="${1:-}" url="${2:-}"
      [ -n "$name" ] && [ -n "$url" ] ||
        die "usage: clankctl project add [--template auto|linux-default] <name> <git-url>"
      valid_name "$name" || die "project names are lowercase letters, digits, - or _"
      local dir="$projects/$name"
      [ -e "$dir" ] && die "project $name already exists"
      mkdir -p "$dir"
      if ! git clone --quiet --mirror "$url" "$dir/mirror.git"; then
        rm -rf "$dir"
        die "could not clone $url"
      fi
      printf 'url=%s\ntemplate=%s\n' "$url" "$template" >"$dir/project.env"
      echo "Added project $name ($(git -C "$dir/mirror.git" symbolic-ref --short HEAD), template $template)"
      ;;
    list)
      local d
      for d in "$projects"/*/; do
        [ -f "$d/project.env" ] || continue
        printf '%-20s %-14s %s\n' "$(basename "$d")" "$(kv "$d/project.env" template)" \
          "$(kv "$d/project.env" url)"
      done
      ;;
    *) die "usage: clankctl project add [--template auto|linux-default] <name> <git-url> | clankctl project list" ;;
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
  elif [ -f "$t/prepare.pid" ] && kill -0 "$(cat "$t/prepare.pid")" 2>/dev/null; then
    echo preparing
  elif [ -f "$t/queued" ]; then
    echo queued
  elif [ -f "$t/status.json" ]; then
    jq -r .state "$t/status.json"
  else
    echo lost
  fi
}

# A task always uses the home volume (and so the sign-in and harness
# sessions) of the user who created it.
use_task_user() {
  local user
  user=$(kv "$tasks/$1/task.env" user)
  valid_name "$user" || die "task $1 has no valid user"
  home_volume="$CLANK_DATA/users/$user/home"
}

# The image a task runs in: its devcontainer image, or the default image.
task_image() {
  if [ -s "$tasks/$1/image" ]; then cat "$tasks/$1/image"; else printf '%s' "$CLANK_IMAGE"; fi
}

# docker run options for a task's environment. The container name defaults
# to the task's own (clank-<id>), which is what marks a task as running.
task_container_opts() {
  local id="$1" t="$tasks/$1" name="${2:-clank-$1}"
  container_opts "$(task_image "$id")"
  printf '%s\n' \
    --init \
    --stop-timeout 30 \
    --name "$name" \
    --label "clankstation.task=$id" \
    --label "clankstation.project=$(kv "$t/task.env" project)" \
    --volume "$t:/clank" \
    --volume "$t/worktree:/workspace" \
    --volume "$CLANK_TASK_RUN:/opt/clankstation/task-run:ro" \
    --volume /nix/store:/nix/store:ro \
    --workdir /workspace
  # A devcontainer's containerEnv. Values that still hold ${...} references
  # are skipped: there is no devcontainer tooling here to resolve them.
  if [ -f "$t/devcontainer.json" ]; then
    jq -r '.containerEnv // {} | to_entries[] | select(.value | test("\\$\\{") | not)
      | "--env", "\(.key)=\(.value)"' "$t/devcontainer.json"
  fi
}

# Run the in-container runner (with the host's bash, through /nix/store).
runner_cmd() {
  printf '%s\n' "$CLANK_BASH" /opt/clankstation/task-run "$1"
}

# Start a headless turn. Detached and owned by dockerd, so it keeps running
# after the SSH session (and clankctl) exit.
start_task() {
  local id="$1" opts cmd image
  use_task_user "$id"
  image=$(task_image "$id")
  require_image "$image"
  mapfile -t opts < <(task_container_opts "$id")
  mapfile -t cmd < <(runner_cmd headless)
  docker run --detach --rm "${opts[@]}" "$image" "${cmd[@]}" >/dev/null
}

# Mark a task failed before it ever ran (for example, its environment didn't build).
fail_task() {
  local t="$tasks/$1"
  mkdir -p "$t/result"
  printf '%s\n' "$2" >"$t/result/summary.md"
  jq -n --arg error "$2" --arg finished "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{state: "failed", mode: "prepare", exit_code: 1, session_id: "", error: $error, finished: $finished}' \
    >"$t/status.json"
}

# ---- queue (design: section 3, "Queue and concurrency") -----------------------
# A task waits in line (a `queued` file in its folder, holding the time it
# joined) while the box already runs max_running tasks (settings/box.env,
# default 1). Running and preparing tasks fill a slot. `clankctl queue run`
# (the clankstation-queue service) starts waiting tasks as slots free up.
# Every check-and-start holds queue.lock, so two starts can't both take the
# last slot (tasks/.queue.lock).

settings_file="$CLANK_DATA/settings/box.env"

max_running() {
  local n=""
  if [ -f "$settings_file" ]; then n=$(kv "$settings_file" max_running); fi
  case "$n" in "" | *[!0-9]*) n=1 ;; esac
  [ "$n" -ge 1 ] || n=1
  printf '%s' "$n"
}

slots_used() {
  local n d pid
  n=$(docker ps -q --filter label=clankstation.task | wc -l)
  for d in "$tasks"/t-*/; do
    [ -f "$d/prepare.pid" ] || continue
    pid=$(cat "$d/prepare.pid" 2>/dev/null) || continue
    if kill -0 "$pid" 2>/dev/null; then n=$((n + 1)); fi
  done
  printf '%s' "$n"
}

# Waiting tasks, oldest first.
queued_tasks() {
  local f
  for f in "$tasks"/t-*/queued; do
    [ -f "$f" ] || continue
    printf '%s %s\n' "$(cat "$f")" "$(basename "$(dirname "$f")")"
  done | sort | cut -d' ' -f2
}

# Run "$@" holding the queue lock. Children started in the background
# (a devcontainer prepare) must not inherit it: they close fd 9.
with_queue_lock() {
  (
    exec 9>>"$tasks/.queue.lock"
    flock 9
    "$@"
  )
}

# Start a task's turn now: a devcontainer task builds its image first.
launch_task() {
  local id="$1" t="$tasks/$1"
  if [ "$(kv "$t/task.env" env)" = devcontainer ] && [ ! -s "$t/image" ]; then
    setsid "$0" _prepare "$id" >>"$t/prepare.log" 2>&1 </dev/null 9>&- &
    echo "$!" >"$t/prepare.pid"
  else
    start_task "$id"
  fi
}

# Start the task now if a slot is free and nobody is waiting; else put it in
# line. Prints "started" or "queued". Call with the queue lock held.
dispatch() {
  local id="$1"
  if [ -z "$(queued_tasks)" ] && [ "$(slots_used)" -lt "$(max_running)" ]; then
    launch_task "$id"
    echo started
  else
    date -u +%Y-%m-%dT%H:%M:%S.%NZ >"$tasks/$id/queued"
    echo queued
  fi
}

# Start waiting tasks while slots are free. Call with the queue lock held.
queue_tick() {
  local id
  while :; do
    id=$(queued_tasks | head -n 1)
    [ -n "$id" ] || return 0
    [ "$(slots_used)" -lt "$(max_running)" ] || return 0
    rm -f "$tasks/$id/queued"
    echo "starting $id"
    (launch_task "$id") || fail_task "$id" "could not start the task"
  done
}

# Take a waiting task out of line. Call with the queue lock held.
cancel_queued() {
  local id="$1" t="$tasks/$1"
  [ -f "$t/queued" ] || return 1
  rm -f "$t/queued"
  jq -n --arg sid "$(session_id "$id")" --arg finished "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{state: "stopped", mode: "headless", exit_code: 0, session_id: $sid, started: "", finished: $finished}' \
    >"$t/status.json"
}

cmd_queue() {
  case "${1:-}" in
    "" | list)
      local id n=0
      echo "At most $(max_running) at a time; $(slots_used) running or preparing."
      while read -r id; do
        [ -n "$id" ] || continue
        n=$((n + 1))
        printf '%2d. %s  %-16s %s\n' "$n" "$id" "$(kv "$tasks/$id/task.env" project)" \
          "$(head -n 1 "$tasks/$id/prompt.txt" | cut -c1-60)"
      done < <(queued_tasks)
      [ "$n" -gt 0 ] || echo "Nobody is waiting."
      ;;
    run)
      # The clankstation-queue service. Checking every few seconds is cheap
      # and catches every way a slot frees up (a task ends, is stopped, a
      # prepare fails, the limit goes up).
      while :; do
        if [ -n "$(queued_tasks)" ]; then with_queue_lock queue_tick || true; fi
        sleep 3
      done
      ;;
    *) die "usage: clankctl queue [list|run]" ;;
  esac
}

cmd_config() {
  case "${1:-}" in
    "" | get) echo "max-running $(max_running)" ;;
    set)
      [ "${2:-}" = max-running ] || die "usage: clankctl config set max-running <n>"
      local n="${3:-}"
      case "$n" in "" | *[!0-9]*) die "max-running is a number from 1 to 64" ;; esac
      [ "$n" -ge 1 ] && [ "$n" -le 64 ] || die "max-running is a number from 1 to 64"
      {
        if [ -f "$settings_file" ]; then grep -v '^max_running=' "$settings_file" || true; fi
        echo "max_running=$n"
      } >"$settings_file.tmp"
      mv "$settings_file.tmp" "$settings_file"
      echo "max-running $n"
      with_queue_lock queue_tick >/dev/null || true
      ;;
    *) die "usage: clankctl config [set max-running <n>]" ;;
  esac
}

# ---- devcontainers -------------------------------------------------------------

devcontainer_config() {
  local wt="$1"
  if [ -f "$wt/.devcontainer/devcontainer.json" ]; then
    echo .devcontainer/devcontainer.json
  elif [ -f "$wt/.devcontainer.json" ]; then
    echo .devcontainer.json
  fi
}

# Build (or reuse) the project's devcontainer image for task $1, then write
# $t/image and $t/devcontainer.json (merged metadata for the runner).
# Output goes to $t/prepare.log.
prepare_devcontainer() {
  local id="$1" t="$tasks/$1" wt="$tasks/$1/worktree" project config hash tag
  project=$(kv "$t/task.env" project)
  config=$(devcontainer_config "$wt")
  # The devcontainers CLI keeps its own state under HOME.
  export HOME="$CLANK_DATA/cache/devcontainer-home"
  mkdir -p "$HOME"

  local read
  read=$(devcontainer read-configuration --workspace-folder "$wt" --log-level info 2>>"$t/prepare.log") || {
    fail_task "$id" "could not read $config (see prepare.log)"
    return 1
  }
  if jq -e '.configuration.dockerComposeFile' >/dev/null <<<"$read"; then
    fail_task "$id" "docker compose devcontainers are not supported yet ($config)"
    return 1
  fi

  # The image is reused while the devcontainer files are unchanged.
  hash=$(
    cd "$wt" && {
      find .devcontainer -type f -print0 2>/dev/null | sort -z | xargs -0r sha256sum
      if [ -f .devcontainer.json ]; then sha256sum .devcontainer.json; fi
      find "$CLANK_AGENT_LAYER" -type f -print0 | sort -z | xargs -0r sha256sum
      echo "$CLANK_UID:$CLANK_GID"
    } | sha256sum | cut -c1-12
  )
  tag="clankstation/dc-$project:$hash"

  if ! docker image inspect "$tag" >/dev/null 2>&1; then
    echo "== devcontainer build ($config)" >>"$t/prepare.log"
    devcontainer build --workspace-folder "$wt" --image-name "$tag-base" \
      >>"$t/prepare.log" 2>&1 || {
      fail_task "$id" "devcontainer build failed (see prepare.log)"
      return 1
    }
    local remote_user
    remote_user=$(docker image inspect -f '{{index .Config.Labels "devcontainer.metadata"}}' "$tag-base" |
      jq -r 'map(.remoteUser // .containerUser // empty) | last // ""')
    echo "== agent layer (remoteUser: ${remote_user:-none})" >>"$t/prepare.log"
    docker build --tag "$tag" \
      --build-arg BASE="$tag-base" \
      --build-arg REMOTE_USER="$remote_user" \
      --build-arg AGENT_UID="$CLANK_UID" \
      --build-arg AGENT_GID="$CLANK_GID" \
      "$CLANK_AGENT_LAYER" >>"$t/prepare.log" 2>&1 || {
      fail_task "$id" "could not add the agent user to the devcontainer image (see prepare.log)"
      return 1
    }
  fi

  # Merge the metadata fragments (features first, then the project's config)
  # the way the devcontainer spec does: last remoteUser wins, containerEnv
  # merges, lifecycle hooks run in order.
  docker image inspect -f '{{index .Config.Labels "devcontainer.metadata"}}' "$tag" | jq '
    def hook(h): map(.[h] // empty);
    {
      remoteUser: (map(.remoteUser // empty) | last),
      containerEnv: (map(.containerEnv // {}) | add // {}),
      onCreateCommand: hook("onCreateCommand"),
      updateContentCommand: hook("updateContentCommand"),
      postCreateCommand: hook("postCreateCommand"),
      postStartCommand: hook("postStartCommand")
    }' >"$t/devcontainer.json"
  printf '%s\n' "$tag" >"$t/image"
}

# Background half of `clankctl run` for devcontainer tasks: build the image,
# then start the task. Detached from the terminal, so it survives SSH
# disconnects.
cmd_prepare() {
  local id="$1" t
  t=$(task_dir "$id")
  echo "$$" >"$t/prepare.pid"
  if prepare_devcontainer "$id"; then
    start_task "$id" || fail_task "$id" "could not start the task container"
  fi
  rm -f "$t/prepare.pid"
}

# Record each turn's prompt, so a task's history survives later turns.
log_turn() {
  local t="$tasks/$1"
  {
    printf -- '--- %s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$2"
    if [ -n "${3:-}" ]; then printf '%s\n' "$3"; fi
  } >>"$t/prompts.log"
}

require_not_running() {
  case "$(task_state "$1")" in
    running) die "task $1 is still running (see: clankctl logs -f $1, or clankctl attach $1)" ;;
    preparing) die "task $1 is still preparing its environment (see: $tasks/$1/prepare.log)" ;;
    queued) die "task $1 is waiting in line (clankctl stop $1 takes it out)" ;;
  esac
}

# The task's harness session id, or nothing if it never ran.
session_id() {
  local t="$tasks/$1" sid=""
  if [ -f "$t/status.json" ]; then sid=$(jq -r '.session_id // ""' "$t/status.json"); fi
  # A lost task (the box went down mid-turn) has no status.json; its events
  # still name the session.
  if [ -z "$sid" ] && [ -f "$t/events.jsonl" ]; then
    sid=$(jq -Rr 'fromjson? | select(.type == "system" and .subtype == "init") | .session_id // empty' \
      "$t/events.jsonl" | tail -n 1)
  fi
  printf '%s' "$sid"
}

session_of() {
  local sid
  sid=$(session_id "$1")
  [ -n "$sid" ] || die "task $1 has no harness session to continue"
  printf '%s' "$sid"
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
  : >"$t/resume"
  log_turn "$id" run "$prompt"
  printf 'project=%s\nbranch=%s\nbase=%s\ncreated=%s\nuser=%s\n' \
    "$name" "$branch" "$base" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$CLANK_USER" >"$t/task.env"

  # A local clone (hardlinked objects, so cheap) keeps the task's repo
  # self-contained; the agent can't damage the mirror.
  git clone --quiet --branch "$branch" "$mirror" "$t/worktree"
  git -C "$t/worktree" remote set-url origin "$(kv "$dir/project.env" url)"
  git -C "$t/worktree" switch --quiet --create "clank/$id"

  local template config
  template=$(kv "$dir/project.env" template)
  config=$(devcontainer_config "$t/worktree")
  if [ "${template:-auto}" = auto ] && [ -n "$config" ]; then
    # Building a devcontainer image can take minutes, so it runs in the
    # background, detached from this terminal; the task starts when it's done.
    echo "env=devcontainer" >>"$t/task.env"
  else
    echo "env=linux-default" >>"$t/task.env"
  fi
  local how
  how=$(with_queue_lock dispatch "$id") || exit 1
  echo "$id"
  if [ "$how" = queued ]; then
    echo "Waiting in line (the box runs $(max_running) at a time). Check on it with: clankctl queue" >&2
  elif [ "$(kv "$t/task.env" env)" = devcontainer ]; then
    echo "Preparing the devcontainer ($config), then starting. Check on it with: clankctl status" >&2
  else
    echo "Started. Check on it with: clankctl status   (or: clankctl show $id)" >&2
  fi
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
  echo "Env:     $(kv "$t/task.env" env) ($(task_image "$id"))"
  echo "State:   $state"
  if [ -f "$t/status.json" ]; then
    echo "Session: $(jq -r .session_id "$t/status.json")"
  fi
  if [ -f "$t/pruned" ]; then
    echo "Cleaned: $(cat "$t/pruned") (worktree removed; results kept)"
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

# A cleaned-up task keeps its results but has no worktree to continue in.
require_worktree() {
  [ -d "$tasks/$1/worktree" ] ||
    die "task $1 was cleaned up ($(cat "$tasks/$1/pruned" 2>/dev/null || echo "date unknown")); its worktree is gone, so it can't continue. Its results remain: clankctl show $1, clankctl diff $1"
}

cmd_resume() {
  local id="${1:-}" prompt="${2:-}" t sid
  [ -n "$id" ] && [ -n "$prompt" ] || die "usage: clankctl resume <task-id> <prompt>"
  t=$(task_dir "$id")
  require_not_running "$id"
  require_worktree "$id"
  sid=$(session_id "$id")
  if [ "$prompt" = - ]; then prompt=$(cat); fi
  if [ -n "$sid" ]; then
    printf '%s\n' "$prompt" >"$t/prompt.txt"
  else
    # Taken out of line before it ever ran: start it now, with its first
    # prompt and this one.
    printf '%s\n\n%s\n' "$(cat "$t/prompt.txt")" "$prompt" >"$t/prompt.txt.new"
    mv "$t/prompt.txt.new" "$t/prompt.txt"
  fi
  printf '%s\n' "$sid" >"$t/resume"
  rm -f "$t/status.json"
  log_turn "$id" resume "$prompt"
  local how
  how=$(with_queue_lock dispatch "$id") || exit 1
  if [ "$how" = queued ]; then
    echo "$id is waiting in line (the box runs $(max_running) at a time)." >&2
  elif [ -n "$sid" ]; then
    echo "Resumed $id (session $sid)." >&2
  else
    echo "Started $id." >&2
  fi
}

cmd_stop() {
  local id="${1:-}"
  [ -n "$id" ] || die "usage: clankctl stop <task-id>"
  task_dir "$id" >/dev/null
  if [ "$(task_state "$id")" = queued ]; then
    with_queue_lock cancel_queued "$id" || die "task $id just started; stop it again"
    echo "$id: stopped (taken out of line)"
    return
  fi
  [ "$(task_state "$id")" = running ] || die "task $id is not running"
  echo "Stopping $id (the agent gets up to 30s to finish its current step)..." >&2
  docker stop "clank-$id" >/dev/null
  # The runner writes status.json on its way out; --rm removes the container.
  local _
  for _ in $(seq 1 20); do
    [ -f "$tasks/$id/status.json" ] && break
    sleep 0.5
  done
  echo "$id: $(task_state "$id")"
}

cmd_attach() {
  local yes=false
  if [ "${1:-}" = --yes ]; then yes=true; shift; fi
  local id="${1:-}" t opts cmd image tty=(-i)
  [ -n "$id" ] || die "usage: clankctl attach [--yes] <task-id>"
  t=$(task_dir "$id")
  [ "$(task_state "$id")" != preparing ] || die "task $id is still preparing its environment"
  [ "$(task_state "$id")" != queued ] || die "task $id is waiting in line (clankctl stop $id takes it out)"
  require_worktree "$id"
  if [ "$(task_state "$id")" = running ]; then
    if [ "$yes" != true ]; then
      [ -t 0 ] || die "task $id is running; pass --yes to stop its headless run and take over"
      local answer
      read -r -p "Task $id is running headless. Stop it and take over interactively? [y/N] " answer
      case "$answer" in y | Y | yes) ;; *) die "not attached" ;; esac
    fi
    cmd_stop "$id" >/dev/null
  fi
  local sid
  sid=$(session_of "$id")
  image=$(task_image "$id")
  require_image "$image"
  use_task_user "$id"
  printf '%s\n' "$sid" >"$t/resume"
  log_turn "$id" attach
  mapfile -t opts < <(task_container_opts "$id")
  mapfile -t cmd < <(runner_cmd interactive)
  if [ -t 0 ] && [ -t 1 ]; then tty+=(-t); fi
  echo "Opening session $sid. Exit Claude Code (/exit) to hand the task back." >&2
  docker run --rm "${tty[@]}" "${opts[@]}" "$image" "${cmd[@]}"
  echo "$id: $(task_state "$id")" >&2
}

# Human-readable view of the harness event stream.
render_events() {
  jq -Rr --unbuffered '
    fromjson? |
    if .type == "system" and .subtype == "init" then "[session " + .session_id + "]"
    elif .type == "assistant" then
      (.message.content[]? |
        if .type == "text" then "● " + .text
        elif .type == "tool_use" then "→ " + .name + " " + ((.input | tostring)[0:160])
        else empty end)
    elif .type == "result" then "✓ " + (if .is_error then "failed: " else "done: " end) + (.result // "")
    else empty end'
}

cmd_logs() {
  local follow=false id t pid
  case "${1:-}" in -f | --follow) follow=true; shift ;; esac
  id="${1:-}"
  case "${2:-}" in -f | --follow) follow=true ;; esac
  [ -n "$id" ] || die "usage: clankctl logs <task-id> [-f]"
  t=$(task_dir "$id")
  touch "$t/events.jsonl"
  if [ "$follow" = true ] && [ "$(task_state "$id")" = running ]; then
    pid=$(docker inspect -f '{{.State.Pid}}' "clank-$id")
    tail -n +1 -f --pid="$pid" "$t/events.jsonl" | render_events
  else
    render_events <"$t/events.jsonl"
  fi
}

# A shell in a task's environment: inside its running container, or in a new
# container on its worktree when it isn't running.
task_shell() {
  local id="${1:-}" t opts tty=(-i)
  [ -n "$id" ] || die "usage: clankctl shell --task <task-id> [cmd...]"
  t=$(task_dir "$id")
  shift
  [ "$#" -gt 0 ] || set -- bash -l
  if [ -t 0 ] && [ -t 1 ]; then tty+=(-t); fi
  if [ "$(task_state "$id")" = running ]; then
    docker exec "${tty[@]}" --user "$CLANK_UID:$CLANK_GID" --workdir /workspace "clank-$id" "$@"
  else
    require_worktree "$id"
    local image
    image=$(task_image "$id")
    require_image "$image"
    use_task_user "$id"
    # Not the task's own container name: a side shell doesn't make the task
    # look running.
    mapfile -t opts < <(task_container_opts "$id" "clank-$id-shell")
    docker run --rm "${tty[@]}" "${opts[@]}" "$image" "$@"
  fi
}

# ---- cleanup (design: 5.3) -------------------------------------------------------

# 7d, 12h, 30m, 90s, 2w -> seconds.
duration_seconds() {
  local n="${1%[smhdw]}" unit="${1: -1}"
  case "$n" in "" | *[!0-9]*) return 1 ;; esac
  case "$unit" in
    s) echo "$n" ;;
    m) echo $((n * 60)) ;;
    h) echo $((n * 3600)) ;;
    d) echo $((n * 86400)) ;;
    w) echo $((n * 604800)) ;;
    *) return 1 ;;
  esac
}

# Remove a directory tree, including read-only parts an agent may have left.
remove_tree() {
  chmod -R u+w "$1" 2>/dev/null || true
  rm -rf "$1"
}

cmd_clean() {
  local older=7d dry=false
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --older-than)
        [ "$#" -ge 2 ] || die "usage: clankctl clean [--older-than 7d] [--dry-run]"
        older="$2"
        shift 2
        ;;
      -n | --dry-run) dry=true; shift ;;
      *) die "usage: clankctl clean [--older-than 7d] [--dry-run]" ;;
    esac
  done
  local secs cutoff
  secs=$(duration_seconds "$older") || die "not a duration: $older (examples: 7d, 12h, 30m)"
  cutoff=$(($(date +%s) - secs))

  local d id state finished fin cleaned=0
  for d in "$tasks"/t-*/; do
    [ -f "$d/task.env" ] || continue
    id=$(basename "$d")
    [ -d "$d/worktree" ] || [ -e "$vm_dir/overlays/$id.qcow2" ] || continue
    state=$(task_state "$id")
    case "$state" in done | failed | stopped) ;; *) continue ;; esac
    finished=$(jq -r '.finished // empty' "$d/status.json" 2>/dev/null || true)
    fin=$(date -d "$finished" +%s 2>/dev/null) || continue
    [ "$fin" -le "$cutoff" ] || continue
    if [ "$dry" = true ]; then
      echo "would clean $id ($state, finished $finished)"
      continue
    fi
    if ! remove_tree "$d/worktree"; then
      echo "clankctl: could not remove $d/worktree" >&2
      continue
    fi
    rm -f "$vm_dir/overlays/$id.qcow2"
    date -u +%Y-%m-%dT%H:%M:%SZ >"$d/pruned"
    echo "cleaned $id ($state, finished $finished)"
    cleaned=$((cleaned + 1))
  done
  [ "$dry" = true ] || echo "Cleaned $cleaned task(s)."
  clean_images "$cutoff" "$dry"
}

# Devcontainer images (clankstation/dc-<project>:<hash>, and its -base image)
# that no task with a worktree uses and that were built before the cutoff.
# A project's next task rebuilds its image if it's gone.
clean_images() {
  local cutoff="$1" dry="$2" d id img created
  local -A used=()
  for d in "$tasks"/t-*/; do
    [ -f "$d/task.env" ] || continue
    id=$(basename "$d")
    # A task still preparing is building an image right now: leave them all.
    [ "$(task_state "$id")" != preparing ] || return 0
    if [ -d "$d/worktree" ] && [ -s "$d/image" ]; then
      used[$(cat "$d/image")]=1
    fi
  done
  while read -r img; do
    [ -n "$img" ] || continue
    [ -z "${used[${img%-base}]:-}" ] || continue
    created=$(docker image inspect -f '{{.Created}}' "$img" 2>/dev/null) || continue
    [ "$(date -d "$created" +%s)" -le "$cutoff" ] || continue
    if [ "$dry" = true ]; then
      echo "would remove image $img"
    elif docker image rm "$img" >/dev/null 2>&1; then
      echo "removed image $img"
    fi
  done < <(docker image ls --format '{{.Repository}}:{{.Tag}}' --filter 'reference=clankstation/dc-*')
}

cmd_delete() {
  local id="${1:-}" t state
  [ -n "$id" ] || die "usage: clankctl delete <task-id>"
  t=$(task_dir "$id")
  state=$(task_state "$id")
  case "$state" in
    running | preparing) die "task $id is $state (clankctl stop $id first)" ;;
  esac
  remove_tree "$t"
  rm -f "$vm_dir/overlays/$id.qcow2"
  echo "Deleted $id."
}

# ---- Windows base images (design: 5.5) ------------------------------------------

export LIBVIRT_DEFAULT_URI=qemu:///system
vm_dir="$CLANK_DATA/vm"

# Microsoft's published generic installation keys: they pick the edition and
# install unactivated. A real key can be passed with --key.
generic_key() {
  case "$1" in
    "Windows 11 Pro") echo VK7JG-NPHTM-C97JM-9MPGT-3V66T ;;
    "Windows 11 Home") echo YTMG3-N6DKC-DKB77-7M9GH-8HVX7 ;;
    "Windows 11 Pro for Workstations") echo DXG7C-N36C4-C4HTG-X4T3X-2YV77 ;;
    "Windows 11 Education") echo YNMGQ-8RYV3-4PGQ3-C8XTP-7CFBY ;;
    *) return 1 ;;
  esac
}

xml_escape() {
  local s="$1"
  s=${s//&/&amp;}
  s=${s//</&lt;}
  s=${s//>/&gt;}
  s=${s//\"/&quot;}
  printf '%s' "$s"
}

# fill_template <file> KEY value [KEY value...]: replace @KEY@ literally.
fill_template() {
  local text
  text=$(cat "$1")
  shift
  while [ "$#" -ge 2 ]; do
    text=${text//"@$1@"/"$2"}
    shift 2
  done
  printf '%s\n' "$text"
}

windows_state() {
  local name="$1"
  if [ -f "$vm_dir/base/$name.json" ]; then
    echo ready
  elif [ -f "$vm_dir/build/$name/state" ]; then
    local state pid
    state=$(cat "$vm_dir/build/$name/state")
    pid=$(cat "$vm_dir/build/$name/pid" 2>/dev/null || echo 0)
    if [ "$state" = building ] && ! kill -0 "$pid" 2>/dev/null; then
      echo "failed: the build process went away"
    else
      echo "$state"
    fi
  else
    echo none
  fi
}

cmd_windows_build() {
  local name="${1:-}"
  [ -n "$name" ] && shift
  valid_name "$name" || die "usage: clankctl windows build-base <name> --iso <file> [options]"
  local iso="" edition="Windows 11 Pro" key="" disk=128G memory=8192 cpus=4 build_tools=true
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --iso) iso="${2:-}"; shift 2 ;;
      --edition) edition="${2:-}"; shift 2 ;;
      --key) key="${2:-}"; shift 2 ;;
      --disk) disk="${2:-}"; shift 2 ;;
      --memory) memory="${2:-}"; shift 2 ;;
      --cpus) cpus="${2:-}"; shift 2 ;;
      --no-build-tools) build_tools=false; shift ;;
      *) die "unknown option: $1" ;;
    esac
  done
  [ -n "$iso" ] || die "--iso is required"
  case "$iso" in /*) ;; *) iso="$vm_dir/iso/$iso" ;; esac
  [ -r "$iso" ] || die "can't read $iso. Copy the ISO onto the box, then: sudo install -o clankstation -g clankstation -m 0644 <file> $vm_dir/iso/"
  [[ "$memory" =~ ^[0-9]+$ ]] && [[ "$cpus" =~ ^[0-9]+$ ]] || die "--memory (MiB) and --cpus are numbers"
  [ -n "$key" ] || key=$(generic_key "$edition") ||
    die "no generic install key for \"$edition\"; pass --key"
  case "$(windows_state "$name")" in
    ready) die "base image $name already exists (clankctl windows remove $name)" ;;
    building) die "base image $name is already being built (clankctl windows log $name)" ;;
  esac

  local b="$vm_dir/build/$name" domain="clank-build-$name" password
  rm -rf "$b"
  mkdir -p "$b/answer/drivers"
  # A Clankstation-generated password for the local `agent` account (console
  # only; task VMs are driven over SSH).
  password="Clank-$(od -An -N12 -tx1 /dev/urandom | tr -d ' \n')"
  (umask 077 && printf '%s\n' "$password" >"$b/password")

  # The answer-file CD: Autounattend.xml, setup.ps1 + config.json, and the
  # virtio drivers setup needs to see the disk and network.
  local d
  for d in viostor vioscsi NetKVM; do
    cp -r "$CLANK_VIRTIO_WIN/$d/w11/amd64" "$b/answer/drivers/$d"
  done
  cp "$CLANK_VIRTIO_WIN/virtio-win-guest-tools.exe" "$CLANK_WINDOWS_TEMPLATES/setup.ps1" "$b/answer/"
  fill_template "$CLANK_WINDOWS_TEMPLATES/Autounattend.xml" \
    LOCALE en-US \
    EDITION "$(xml_escape "$edition")" \
    PRODUCT_KEY "$(xml_escape "$key")" \
    PASSWORD "$(xml_escape "$password")" >"$b/answer/Autounattend.xml"
  jq -n --arg name "$name" --argjson tools "$build_tools" \
    '{name: $name, buildTools: (if $tools then ["Microsoft.VisualStudio.Workload.VCTools"] else [] end)}' \
    >"$b/answer/config.json"
  chmod -R u+w "$b/answer"
  # (from $b: genisoimage looks for rc files in the current directory)
  (cd "$b" && genisoimage -quiet -J -joliet-long -r -V CLANKSETUP -o answer.iso answer)

  qemu-img create -q -f qcow2 "$b/disk.qcow2" "$disk"
  : >"$b/serial.log"
  chmod 0644 "$b/serial.log"

  local domain_type=kvm cpu_mode=host-passthrough
  if [ ! -e /dev/kvm ]; then domain_type=qemu cpu_mode=maximum; fi
  fill_template "$CLANK_WINDOWS_TEMPLATES/build-domain.xml" \
    DOMAIN_TYPE "$domain_type" \
    CPU_MODE "$cpu_mode" \
    DOMAIN "$domain" \
    MEMORY_MIB "$memory" \
    CPUS "$cpus" \
    DISK "$b/disk.qcow2" \
    WINDOWS_ISO "$(xml_escape "$iso")" \
    ANSWER_ISO "$b/answer.iso" \
    SERIAL_LOG "$b/serial.log" >"$b/domain.xml"
  printf 'name=%s\ndomain=%s\niso=%s\nedition=%s\ndisk=%s\nstarted=%s\n' \
    "$name" "$domain" "$iso" "$edition" "$disk" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$b/build.env"

  if [ "${CLANK_WINDOWS_DRY_RUN:-}" = 1 ]; then
    echo "dry run: files in $b"
    return
  fi
  echo building >"$b/state"
  setsid "$0" _windows-build "$name" >>"$b/build.log" 2>&1 </dev/null &
  echo "$!" >"$b/pid"
  echo "Building Windows base image $name ($edition). This takes about an hour."
  echo "Follow it with: clankctl windows log $name -f"
}

# Background half of build-base: run the install VM until it powers off.
cmd_windows_build_run() {
  local name="$1" b="$vm_dir/build/$1" domain
  domain=$(kv "$b/build.env" domain)
  if ! virsh create "$b/domain.xml"; then
    echo "failed: could not start the install VM (see $b/build.log)" >"$b/state"
    return 1
  fi
  # The Windows DVD's boot loader waits for "press any key".
  local _
  for _ in $(seq 1 20); do
    virsh send-key "$domain" KEY_ENTER >/dev/null 2>&1 || break
    sleep 1.5
  done
  local deadline=$((SECONDS + 4 * 3600))
  while [ "$(virsh domstate "$domain" 2>/dev/null)" = running ]; do
    if [ "$SECONDS" -ge "$deadline" ]; then
      virsh destroy "$domain" >/dev/null 2>&1 || true
      echo "failed: setup didn't finish within 4 hours (see: clankctl windows log $name)" >"$b/state"
      return 1
    fi
    # Keep the latest screen, so a stuck or failed setup can be seen
    # (clankctl windows screenshot).
    if virsh screenshot "$domain" "$b/screen.raw" >/dev/null 2>&1; then
      # libvirt hands back PNG or PPM depending on the display backend.
      if [ "$(head -c 4 "$b/screen.raw" | od -An -tx1 | tr -d ' \n')" = 89504e47 ]; then
        mv "$b/screen.raw" "$b/screen.png"
      elif pnmtopng "$b/screen.raw" >"$b/screen.png.tmp" 2>/dev/null; then
        mv "$b/screen.png.tmp" "$b/screen.png"
      fi
      rm -f "$b/screen.raw" "$b/screen.png.tmp"
    fi
    sleep 20
  done
  if grep -q CLANK-SETUP-DONE "$b/serial.log"; then
    mv "$b/disk.qcow2" "$vm_dir/base/$name.qcow2"
    chmod 0444 "$vm_dir/base/$name.qcow2"
    install -m 0600 "$b/password" "$vm_dir/base/$name.password"
    jq -n --arg name "$name" --arg edition "$(kv "$b/build.env" edition)" \
      --arg iso "$(basename "$(kv "$b/build.env" iso)")" \
      --arg created "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      --argjson tools "$(jq .buildTools "$b/answer/config.json")" \
      '{name: $name, edition: $edition, iso: $iso, created: $created, buildTools: $tools, user: "agent"}' \
      >"$vm_dir/base/$name.json"
    echo ready >"$b/state"
  else
    local reason
    reason=$(tr -d '\r' <"$b/serial.log" | grep -o 'CLANK-SETUP-FAILED.*' | tail -n 1 || true)
    echo "failed: ${reason:-the VM stopped before setup finished (see: clankctl windows log $name)}" >"$b/state"
  fi
}

cmd_windows() {
  case "${1:-}" in
    build-base) shift; cmd_windows_build "$@" ;;
    list)
      local f name
      printf '%-20s %-10s %s\n' NAME STATE DETAILS
      for f in "$vm_dir"/base/*.json; do
        [ -f "$f" ] || continue
        name=$(basename "$f" .json)
        printf '%-20s %-10s %s, %s on disk, built %s\n' "$name" ready "$(jq -r .edition "$f")" \
          "$(du -h "$vm_dir/base/$name.qcow2" | cut -f1)" "$(jq -r .created "$f")"
      done
      for f in "$vm_dir"/build/*/state; do
        [ -f "$f" ] || continue
        name=$(basename "$(dirname "$f")")
        [ -f "$vm_dir/base/$name.json" ] && continue
        printf '%-20s %-10s %s\n' "$name" "$(windows_state "$name" | cut -d: -f1)" \
          "$(tr -d '\r' <"$vm_dir/build/$name/serial.log" | tail -n 1 | cut -c1-80)"
      done
      ;;
    log)
      local name="${2:-}" follow="${3:-}"
      valid_name "$name" || die "usage: clankctl windows log <name> [-f]"
      [ -f "$vm_dir/build/$name/serial.log" ] || die "no build log for $name"
      echo "state: $(windows_state "$name")" >&2
      if [ "$follow" = -f ] && [ "$(windows_state "$name")" = building ]; then
        tail -n +1 -f --pid="$(cat "$vm_dir/build/$name/pid")" "$vm_dir/build/$name/serial.log" | tr -d '\r'
      else
        tr -d '\r' <"$vm_dir/build/$name/serial.log"
      fi
      ;;
    screenshot)
      local name="${2:-}" out="${3:-}"
      valid_name "$name" && [ -n "$out" ] || die "usage: clankctl windows screenshot <name> <file.png>"
      [ -f "$vm_dir/build/$name/screen.png" ] || die "no screenshot of $name yet"
      cat "$vm_dir/build/$name/screen.png" >"$out"
      echo "Saved the build VM's screen to $out ($(date -r "$vm_dir/build/$name/screen.png" +%H:%M:%S))."
      ;;
    cancel)
      local name="${2:-}"
      valid_name "$name" || die "usage: clankctl windows cancel <name>"
      [ "$(windows_state "$name")" = building ] || die "$name is not building"
      virsh destroy "clank-build-$name" >/dev/null 2>&1 || true
      kill "$(cat "$vm_dir/build/$name/pid")" 2>/dev/null || true
      echo "failed: cancelled" >"$vm_dir/build/$name/state"
      echo "Cancelled."
      ;;
    remove)
      local name="${2:-}"
      valid_name "$name" || die "usage: clankctl windows remove <name>"
      [ "$(windows_state "$name")" != building ] || die "$name is building (clankctl windows cancel $name)"
      rm -f "$vm_dir/base/$name.qcow2" "$vm_dir/base/$name.json" "$vm_dir/base/$name.password"
      rm -rf "${vm_dir:?}/build/$name"
      echo "Removed $name."
      ;;
    *) die "usage: clankctl windows build-base|list|log|cancel|remove" ;;
  esac
}

case "${1:-}" in
  windows) shift; cmd_windows "$@" ;;
  queue) shift; cmd_queue "$@" ;;
  config) shift; cmd_config "$@" ;;
  _windows-build) shift; cmd_windows_build_run "$@" ;;
  _prepare) shift; cmd_prepare "$@" ;;
  resume) shift; cmd_resume "$@" ;;
  stop) shift; cmd_stop "$@" ;;
  attach) shift; cmd_attach "$@" ;;
  logs) shift; cmd_logs "$@" ;;
  harness) shift; cmd_harness "$@" ;;
  login) shift; cmd_login "$@" ;;
  shell) shift; cmd_shell "$@" ;;
  project) shift; cmd_project "$@" ;;
  run) shift; cmd_run "$@" ;;
  status) shift; cmd_status "$@" ;;
  show) shift; cmd_show "$@" ;;
  diff) shift; cmd_diff "$@" ;;
  clean) shift; cmd_clean "$@" ;;
  delete) shift; cmd_delete "$@" ;;
  -h | --help | help | "") usage ;;
  *) usage >&2; exit 1 ;;
esac
