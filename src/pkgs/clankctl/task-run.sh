# Task runner: runs inside the task container, started by clankctl.
# An early, shell-only form of the per-environment worker (design: section 4).
#
# Usage: task-run headless      run (or resume) the harness with prompt.txt
#        task-run interactive   open the session in an interactive terminal
#
# The runner's own tools (bash, coreutils, git, jq) come from the host's
# /nix/store, mounted read-only, so it works in any image (default image or a
# project's devcontainer). CLANK_TOOLS is set by the Nix wrapper. The harness
# and devcontainer lifecycle commands run with the image's own PATH.
#
# Mounts:
#   /workspace   the task's clone of the project (git)
#   /clank       the task directory on the host:
#                  prompt.txt        the prompt for this headless turn (input)
#                  base              base commit sha (input)
#                  resume            session id to resume; empty on the first turn (input)
#                  devcontainer.json merged devcontainer metadata, if any (input)
#                  events.jsonl      harness stream-json events, appended per turn (output)
#                  stderr.log        harness stderr (output)
#                  lifecycle.log     devcontainer lifecycle command output (output)
#                  status.json       final state (output, written last)
#                  result/           summary.md, diff.patch, diffstat.txt (output)
#   /home/agent  the user's home volume (harness install + sign-in)
#   /nix/store   the host's Nix store, read-only (runner tools)
#
# Harness rule: the harness runs unmodified, never with --bare.
set -u

agent_path=$PATH
PATH=$CLANK_TOOLS/bin:$PATH

mode="${1:-headless}"
cd /workspace || exit 1
mkdir -p /clank/result
started=$(date -u +%Y-%m-%dT%H:%M:%SZ)
resume_id=$(cat /clank/resume 2>/dev/null || true)
touch /clank/events.jsonl
events_before=$(wc -l </clank/events.jsonl)

# This turn's events only.
turn_events() {
  tail -n "+$((events_before + 1))" /clank/events.jsonl
}

# Run a program with the image's PATH, not the runner's.
as_agent() {
  PATH=$agent_path "$@"
}

# docker stop sends SIGTERM (via --init); pass it on to the harness and
# still write the results.
stopped=false
child=
on_term() {
  stopped=true
  if [ -n "$child" ]; then kill -TERM "$child" 2>/dev/null; fi
}
trap on_term TERM INT

# ---- devcontainer lifecycle commands ----------------------------------------
# devcontainer.json holds each lifecycle hook as a list of commands, one per
# metadata fragment (features first, then the project's config). A command is
# a string (run by /bin/sh -c), an array (run directly) or an object of named
# commands (run in turn).

run_command() {
  local cmd="$1" kind
  kind=$(jq -r 'type' <<<"$cmd")
  case "$kind" in
    string) as_agent /bin/sh -c "$(jq -r . <<<"$cmd")" ;;
    array)
      local argv=()
      mapfile -t argv < <(jq -r '.[]' <<<"$cmd")
      as_agent "${argv[@]}"
      ;;
    object)
      local sub rc=0
      while IFS= read -r sub; do
        run_command "$sub" || rc=$?
      done < <(jq -c '.[]' <<<"$cmd")
      return "$rc"
      ;;
    *) return 0 ;;
  esac
}

run_lifecycle() {
  [ -f /clank/devcontainer.json ] || return 0
  local hooks=(postStartCommand) hook cmd rc
  # The create hooks run once per task, on its first container.
  if [ ! -f /clank/.lifecycle-created ]; then
    hooks=(onCreateCommand updateContentCommand postCreateCommand postStartCommand)
  fi
  for hook in "${hooks[@]}"; do
    while IFS= read -r cmd; do
      echo "--- $hook: $cmd" >>/clank/lifecycle.log
      run_command "$cmd" >>/clank/lifecycle.log 2>&1 </dev/null
      rc=$?
      # Like a failed postCreateCommand in an editor: note it and carry on;
      # the agent can see the log and fix things.
      if [ "$rc" -ne 0 ]; then echo "--- $hook failed (exit $rc)" >>/clank/lifecycle.log; fi
    done < <(jq -c --arg h "$hook" '.[$h] // [] | .[]' /clank/devcontainer.json)
  done
  touch /clank/.lifecycle-created
}

# ---- harness ------------------------------------------------------------------

run_headless() {
  local args=(-p "$(cat /clank/prompt.txt)" --output-format stream-json --verbose
    --permission-mode bypassPermissions)
  if [ -n "$resume_id" ]; then args+=(--resume "$resume_id"); fi
  # exec, so $! is the harness itself and SIGTERM reaches it.
  (
    PATH=$agent_path
    exec claude "${args[@]}"
  ) >>/clank/events.jsonl 2>>/clank/stderr.log </dev/null &
  child=$!
  rc=0
  # `wait` returns early when a trapped signal arrives; keep waiting.
  while kill -0 "$child" 2>/dev/null; do
    wait "$child"
    rc=$?
  done
}

run_interactive() {
  [ -n "$resume_id" ] || {
    echo "task-run: no session to open" >&2
    exit 1
  }
  as_agent claude --resume "$resume_id" --permission-mode bypassPermissions
  rc=$?
}

write_diff() {
  # Against the base commit, including untracked files, without touching the
  # agent's own index.
  local base index
  base=$(cat /clank/base)
  index=$(mktemp)
  if [ -f .git/index ]; then cp .git/index "$index"; fi
  GIT_INDEX_FILE=$index git add -A
  GIT_INDEX_FILE=$index git diff --cached --binary "$base" >/clank/result/diff.patch
  GIT_INDEX_FILE=$index git diff --cached --stat "$base" >/clank/result/diffstat.txt
  rm -f "$index"
}

case "$mode" in
  headless | interactive) ;;
  *) echo "task-run: unknown mode $mode" >&2; exit 2 ;;
esac

run_lifecycle
if [ "$mode" = headless ]; then run_headless; else run_interactive; fi

# Session id and summary from this turn's events. An interactive session
# writes no events, so the previous summary stays.
session_id=$(turn_events | jq -r 'select(.type == "system" and .subtype == "init") | .session_id' \
  2>/dev/null | tail -n 1)
[ -n "$session_id" ] || session_id=$resume_id
is_error=false
if [ "$mode" = headless ]; then
  result_line=$(turn_events | jq -c 'select(.type == "result")' 2>/dev/null | tail -n 1)
  if [ -n "$result_line" ]; then
    jq -r '.result // ""' <<<"$result_line" >/clank/result/summary.md
    is_error=$(jq -r '.is_error // false' <<<"$result_line")
  else
    : >/clank/result/summary.md
    is_error=true
  fi
fi

write_diff

if [ "$stopped" = true ]; then
  state=stopped
elif [ "$rc" -eq 0 ] && [ "$is_error" != true ]; then
  state=done
else
  state=failed
fi

jq -n \
  --arg state "$state" \
  --arg mode "$mode" \
  --argjson exit_code "$rc" \
  --arg session_id "$session_id" \
  --arg started "$started" \
  --arg finished "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{state: $state, mode: $mode, exit_code: $exit_code, session_id: $session_id,
    started: $started, finished: $finished}' \
  >/clank/status.json.tmp
mv /clank/status.json.tmp /clank/status.json
