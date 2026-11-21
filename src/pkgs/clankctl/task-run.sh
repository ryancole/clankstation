# Task runner: runs inside the task container, started by `clankctl run`.
# An early, shell-only form of the per-environment worker (design: section 4).
#
# Mounts:
#   /workspace   the task's clone of the project (git)
#   /clank       the task directory on the host:
#                  prompt.txt   the prompt (input)
#                  base         base commit sha (input)
#                  resume       optional: session id to resume (input)
#                  events.jsonl harness stream-json events (output)
#                  stderr.log   harness stderr (output)
#                  status.json  final state (output, written last)
#                  result/      summary.md, diff.patch, diffstat.txt (output)
#   /home/agent  the user's home volume (harness install + sign-in)
#
# Harness rule: the harness runs unmodified, never with --bare.
set -u

cd /workspace || exit 1
mkdir -p /clank/result

args=(-p "$(cat /clank/prompt.txt)" --output-format stream-json --verbose
  --permission-mode bypassPermissions)
if [ -s /clank/resume ]; then
  args+=(--resume "$(cat /clank/resume)")
fi

started=$(date -u +%Y-%m-%dT%H:%M:%SZ)
claude "${args[@]}" >>/clank/events.jsonl 2>>/clank/stderr.log </dev/null
rc=$?

# Summary and session id from the event stream (last values win, so a resumed
# run reports its own result).
session_id=$(jq -r 'select(.type == "system" and .subtype == "init") | .session_id' \
  /clank/events.jsonl 2>/dev/null | tail -n 1)
result_line=$(jq -c 'select(.type == "result")' /clank/events.jsonl 2>/dev/null | tail -n 1)
if [ -n "$result_line" ]; then
  jq -r '.result // ""' <<<"$result_line" >/clank/result/summary.md
  is_error=$(jq -r '.is_error // false' <<<"$result_line")
else
  : >/clank/result/summary.md
  is_error=true
fi

# Diff against the base commit, including untracked files, without touching
# the agent's own index.
base=$(cat /clank/base)
index=$(mktemp)
if [ -f .git/index ]; then cp .git/index "$index"; fi
GIT_INDEX_FILE=$index git add -A
GIT_INDEX_FILE=$index git diff --cached --binary "$base" >/clank/result/diff.patch
GIT_INDEX_FILE=$index git diff --cached --stat "$base" >/clank/result/diffstat.txt
rm -f "$index"

if [ "$rc" -eq 0 ] && [ "$is_error" != true ]; then state=done; else state=failed; fi

jq -n \
  --arg state "$state" \
  --argjson exit_code "$rc" \
  --arg session_id "$session_id" \
  --arg started "$started" \
  --arg finished "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{state: $state, exit_code: $exit_code, session_id: $session_id, started: $started, finished: $finished}' \
  >/clank/status.json.tmp
mv /clank/status.json.tmp /clank/status.json
