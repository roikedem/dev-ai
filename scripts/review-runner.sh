#!/usr/bin/env bash
# Review lane of the pipeline: pops one `review` task and runs the Reviewer on it.
# Usage: review-runner.sh <project-dir>   (cron, every 2 min, via for-all-projects.sh)
#
# Runs in PARALLEL with claude-jira-cron.sh. The dev runner is one-at-a-time per
# project because every dev task shares the project's git checkout; a review only
# reads Jira and GitHub and works in a temp dir, so it has its own lock and its own
# queue lane (queue.sh ... review) and a review never waits behind a long dev task.

REPO_ROOT="${1:?Usage: review-runner.sh <project-dir>}"
DEV_AI_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LOCK="$REPO_ROOT/.claude-review.lock"
LOG="$REPO_ROOT/logs/claude-review.log"
QUEUE_SH="$DEV_AI_ROOT/scripts/queue.sh"
MAX_FAILS=3

ts()  { date '+%Y-%m-%d %H:%M:%S'; }
log() { echo "[$(ts)] $*" >> "$LOG"; }

mkdir -p "$REPO_ROOT/logs"
export PATH="$HOME/.local/bin:/usr/local/bin:$PATH"

[ "$("$DEV_AI_ROOT/scripts/read-main-switch.sh" | tr -d '\r\n')" = "ON" ] || exit 0

exec 9>"$LOCK"
flock -n 9 || exit 0

# Share the dev lane's usage-limit pause: same subscription window.
LIMIT_FILE="$REPO_ROOT/.claude-usage-limit"
if [ -f "$LIMIT_FILE" ] && [ "$(date +%s)" -lt "$(cat "$LIMIT_FILE" 2>/dev/null || echo 0)" ]; then
    exit 0
fi

while IFS= read -r line; do
    [ -n "$line" ] && log "recovered stuck review: $line"
done <<< "$("$QUEUE_SH" recover "$REPO_ROOT" review)"

COUNT=$("$QUEUE_SH" count "$REPO_ROOT" review 2>/dev/null) || { log "ABORT — queue database unreachable"; exit 1; }
case "$COUNT" in ''|*[!0-9]*) COUNT=0 ;; esac
[ "$COUNT" -eq 0 ] && exit 0

TASK=$("$QUEUE_SH" pop "$REPO_ROOT" review)
TASK_ID=$(echo "$TASK" | jq -r '.id // ""')
KEY=$(echo "$TASK" | jq -r '.key // ""')
[ -z "$TASK_ID" ] && exit 0

log "starting review $KEY"
OUT=$(python3 "$DEV_AI_ROOT/scripts/review-tickets.py" --key "$KEY" 2>&1)
EXIT=$?
while IFS= read -r line; do echo "[$(ts)] $line" >> "$LOG"; done <<< "$OUT"

# A persistent error (bad ticket data, model reply never valid JSON) must not retry
# every 2 minutes forever: after MAX_FAILS, drop the task and tell the team log.
FAILS_FILE="$REPO_ROOT/logs/.review-fails-$KEY"
if [ $EXIT -eq 0 ]; then
    rm -f "$FAILS_FILE"
    "$QUEUE_SH" done "$REPO_ROOT" "$TASK_ID"
    log "review $KEY finished"
else
    FAILS=$(( $(cat "$FAILS_FILE" 2>/dev/null || echo 0) + 1 ))
    echo "$FAILS" > "$FAILS_FILE"
    if [ "$FAILS" -ge "$MAX_FAILS" ]; then
        rm -f "$FAILS_FILE"
        "$QUEUE_SH" done "$REPO_ROOT" "$TASK_ID"
        log "review $KEY failed $FAILS times — dropped"
        bash "$HOME/projects/team/scripts/log.sh" "Reviewer" WARN \
            "review of $KEY failed $FAILS times, dropped; ticket still in Review on the agent. See $LOG"
    else
        "$QUEUE_SH" requeue "$REPO_ROOT" "$TASK_ID"
        log "review $KEY failed (exit $EXIT, attempt $FAILS/$MAX_FAILS) — requeued"
    fi
fi
