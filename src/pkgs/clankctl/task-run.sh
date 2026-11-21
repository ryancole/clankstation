# Task runner: runs inside the task container, started by clankctl.
# An early, shell-only form of the per-environment worker (design: section 4).
#
# Usage: task-run headless      run (or resume) the harness with prompt.txt
#        task-run interactive   open the session in an interactive terminal
#
# Mounts:
#   /workspace   the task's clone of the project (git)
#   /clank       the task directory on the host:
#                  prompt.txt   the prompt for this headless turn (input)
#                  base         base commit sha (input)
#                  resume       session id to resume; empty for the first turn (input)
#                  events.jsonl harness stream-json events, appended per turn (output)
#                  stderr.log   harness stderr (output)
#                  status.json  final state (output, written last)
#                  result/      summary.md, diff.patch, diffstat.txt (output)
#   /home/agent  the user's home volume (harness install + sign-in)
#
# Harness rule: the harness runs unmodified, never with --bare.
set -u

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

# docker stop sends SIGTERM (via --init); pass it on to the harness and
# still write the results.
stopped=false
child=
on_term() {
  stopped=true
  if [ -n "$child" ]; then kill -TERM "$child" 2>/dev/null; fi
}
trap on_term TERM INT

run_headless() {
  local args=(-p "$(cat /clank/prompt.txt)" --output-format stream-json --verbose
    --permission-mode bypassPermissions)
  if [ -n "$resume_id" ]; then args+=(--resume "$resume_id"); fi
  claude "${args[@]}" >>/clank/events.jsonl 2>>/clank/stderr.log </dev/null &
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
  claude --resume "$resume_id" --permission-mode bypassPermissions
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
  headless) run_headless ;;
  interactive) run_interactive ;;
  *) echo "task-run: unknown mode $mode" >&2; exit 2 ;;
esac

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
