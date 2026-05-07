#!/usr/bin/env bash

REPO_ROOT="${1:?Usage: claude-jira-cron.sh <project-dir>}"
DEV_AI_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LOCK="$REPO_ROOT/.claude-jira.lock"
LOG="$REPO_ROOT/logs/claude-jira.log"
READ_MAIN_SWITCH="$DEV_AI_ROOT/scripts/read-main-switch.sh"

ts()  { date '+%Y-%m-%d %H:%M:%S'; }
log() { echo "[$(ts)] $*" >> "$LOG"; }

mkdir -p "$REPO_ROOT/logs"
cd "$REPO_ROOT"

# Cron has a minimal PATH — extend it with common user install locations
export PATH="$HOME/.local/bin:/usr/local/bin:$PATH"

SWITCH="$($READ_MAIN_SWITCH | tr -d '\r\n')"

if [[ "$SWITCH" == "ON" ]]; then
  # continue with the script
  :
else
  log "Main Switch is $SWITCH, quitting"
  exit 0
fi


source "$DEV_AI_ROOT/scripts/session-setup.sh"

CLAUDE=$(which claude 2>/dev/null)
if [ -z "$CLAUDE" ]; then
    log "claude not found in PATH"
    exit 1
fi

QUEUE_SH="$DEV_AI_ROOT/scripts/queue.sh"

exec 9>"$LOCK"
if ! flock -n 9; then
    log "skipped — claude already running on this host"
    exit 0
fi

# Recover any in_progress tasks left by a previous crash on this host
# (only reached if the lock was NOT held, meaning no Claude is running)
RECOVERED=$("$QUEUE_SH" recover "$REPO_ROOT")
if [ -n "$RECOVERED" ]; then
    while IFS= read -r line; do
        log "recovered stuck task: $line"
    done <<< "$RECOVERED"
fi

QUEUE_COUNT=$("$QUEUE_SH" count "$REPO_ROOT" 2>/dev/null || echo 0)
if [ "$QUEUE_COUNT" -eq 0 ]; then
    log "queue empty — skipping claude"
    exit 0
fi

# Pop the next task and export its fields as env vars for Claude
TASK=$("$QUEUE_SH" pop "$REPO_ROOT")
export TASK_JSON="$TASK"

export TASK_ID=$(echo "$TASK"          | jq -r '.id          // ""')
export TASK_TYPE=$(echo "$TASK"        | jq -r '.type        // ""')
export TASK_KEY=$(echo "$TASK"         | jq -r '.key         // ""')
export TASK_SUMMARY=$(echo "$TASK"     | jq -r '.summary     // ""')
export TASK_COMMENT_ID=$(echo "$TASK"  | jq -r '.comment_id  // ""')
export TASK_COMMENT_BODY=$(echo "$TASK"| jq -r '.body        // ""')
export TASK_COMMENT_AUTHOR=$(echo "$TASK" | jq -r '.author   // ""')
export TASK_PR_NUMBER=$(echo "$TASK"   | jq -r '.pr_number   // ""')
export TASK_PR_TITLE=$(echo "$TASK"    | jq -r '.pr_title    // ""')
export TASK_BRANCH=$(echo "$TASK"      | jq -r '.branch      // ""')
export TASK_REVIEW_STATE=$(echo "$TASK"| jq -r '.state       // ""')
export TASK_CONTEXT_DIRECTORY="$HOME/dev-context/$TASK_KEY"
export TASK_CONTEXT_FILE="$TASK_CONTEXT_DIRECTORY/context.txt"


mkdir -p "$TASK_CONTEXT_DIRECTORY"

GH_USER=$(GH_TOKEN="$GH_TOKEN" gh api user --jq .login 2>/dev/null || echo "unknown")
log "starting claude — task: $TASK_TYPE ${TASK_KEY}${TASK_PR_NUMBER} — gh user: $GH_USER ($CLAUDE)"

CLAUDE_OUTFILE=$(mktemp /tmp/claude-output-XXXXXX)
IDLE_TIMEOUT=900  # 15 minutes
WATCH_DIR="$HOME/dev-context"
MARK=$(mktemp /tmp/claude-mark-XXXXXX)
IDLE=0

"$CLAUDE" --dangerously-skip-permissions --output-format json \
    -p "Follow the Entry Point section in $DEV_AI_ROOT/PROCESS-TASK.md." \
    > "$CLAUDE_OUTFILE" 2>&1 &
CLAUDE_PID=$!

while kill -0 "$CLAUDE_PID" 2>/dev/null; do
    sleep 60
    if find "$WATCH_DIR" -newer "$MARK" -type f 2>/dev/null | grep -q .; then
        touch "$MARK"
        IDLE=0
    else
        IDLE=$((IDLE + 60))
        if [ "$IDLE" -ge "$IDLE_TIMEOUT" ]; then
            log "timeout — no dev-context write for $((IDLE_TIMEOUT / 60)) min; killing claude (pid $CLAUDE_PID)"
            kill "$CLAUDE_PID"
            break
        fi
    fi
done

wait "$CLAUDE_PID"
EXIT=$?
rm -f "$MARK"
CLAUDE_OUTPUT=$(cat "$CLAUDE_OUTFILE")
rm -f "$CLAUDE_OUTFILE"

# Log all output lines with timestamps
while IFS= read -r line; do
    echo "[$(ts)] $line" >> "$LOG"
done <<< "$CLAUDE_OUTPUT"

# Extract and log token usage from JSON result
USAGE_LINE=$(echo "$CLAUDE_OUTPUT" | python3 -c "
import sys, json
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        obj = json.loads(line)
        if obj.get('type') == 'result':
            u = obj.get('usage', {})
            cost = obj.get('total_cost_usd', 0)
            print(f\"tokens in={u.get('input_tokens',0)} cache_read={u.get('cache_read_input_tokens',0)} out={u.get('output_tokens',0)} cost=\${cost:.4f}\")
            break
    except Exception:
        pass
" 2>/dev/null)
[ -n "$USAGE_LINE" ] && log "usage: $USAGE_LINE"
log "claude finished (exit $EXIT)"

if [ $EXIT -eq 0 ]; then
    [ -n "$TASK_ID" ] && "$QUEUE_SH" done "$REPO_ROOT" "$TASK_ID"
else
    [ -n "$TASK_ID" ] && "$QUEUE_SH" requeue "$REPO_ROOT" "$TASK_ID"
fi
