# clankctl: Clankstation admin CLI for the OS phase (design: section 5.8).
#
# Expects these variables, set by the Nix wrapper (src/pkgs/clankctl/default.nix):
#   CLANK_DATA        data root, e.g. /var/lib/clankstation
#   CLANK_UID/GID     uid/gid of the clankstation user and the container agent
#   CLANK_IMAGE       default Linux task image
#
# Harness rule: clankctl never reads, copies or prints harness credentials.
# Sign-in happens inside the container through the vendor's own flow, and
# the harness stores its token in the user's home volume.

CLANK_USER="${CLANK_USER:-default}"

usage() {
  cat <<'EOF'
Usage: clankctl <command> [args]

Harness (per-user, opt-in):
  harness enable claude   Install Claude Code into your home volume (official installer)
  harness status          Show installed harnesses and whether you are signed in
  login claude            Sign in to Claude Code (vendor's own sign-in flow)

Environments:
  shell [cmd...]          Open a shell (or run cmd) in the default Linux image
                          with your home volume mounted

Environment variables:
  CLANK_USER              Household user whose home volume to use (default: default)
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

case "$CLANK_USER" in
  "" | *[!a-z0-9_-]*) die "CLANK_USER must be lowercase letters, digits, - or _" ;;
esac

home_volume="$CLANK_DATA/users/$CLANK_USER/home"

ensure_home_volume() {
  if [ ! -d "$home_volume" ]; then
    mkdir -p "$home_volume"
    chmod 0700 "$home_volume"
  fi
}

# docker run in the default image, as agent, with the home volume mounted.
# Usage: env_run [docker-run-options...] -- command [args...]
env_run() {
  ensure_home_volume
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
  docker image inspect "$CLANK_IMAGE" >/dev/null 2>&1 ||
    die "image $CLANK_IMAGE is not built yet (see: systemctl status clankstation-image-linux-default)"
  docker run --rm "${tty[@]}" \
    --user "$CLANK_UID:$CLANK_GID" \
    --env HOME=/home/agent \
    --env PATH=/home/agent/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    --volume "$home_volume:/home/agent" \
    --workdir /home/agent \
    "${opts[@]}" \
    "$CLANK_IMAGE" "$@"
}

# First use of a home volume: copy the image's shell dotfiles in.
# No stdin attached, so it can't eat input meant for the command that follows.
init_home() {
  env_run --interactive=false --tty=false -- sh -c 'cp -rn /etc/skel/. "$HOME"/ 2>/dev/null || true'
}

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

case "${1:-}" in
  harness) shift; cmd_harness "$@" ;;
  login) shift; cmd_login "$@" ;;
  shell) shift; cmd_shell "$@" ;;
  -h | --help | help | "") usage ;;
  *) usage >&2; exit 1 ;;
esac
