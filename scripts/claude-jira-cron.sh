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
QUEUE_COUNT=$("$QUEUE_SH" count "$REPO_ROOT" 2>/dev/null || echo 0)
if [ "$QUEUE_COUNT" -eq 0 ]; then
    log "queue empty — skipping claude"
    exit 0
fi

exec 9>"$LOCK"
if ! flock -n 9; then
    log "skipped — lock held by another instance"
    exit 0
fi

IN_PROGRESS="$REPO_ROOT/.jira-in-progress.jsonl"

# Pop the next task and export its fields as env vars for Claude
TASK=$("$QUEUE_SH" pop "$REPO_ROOT")
export TASK_JSON="$TASK"

# Track task as in-progress until Claude finishes
echo "$TASK" >> "$IN_PROGRESS"
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

log "starting claude — task: $TASK_TYPE ${TASK_KEY}${TASK_PR_NUMBER} ($CLAUDE)"
"$CLAUDE" --dangerously-skip-permissions \
    -p "Follow the Entry Point section in $DEV_AI_ROOT/PROCESS-TASK.md." \
    2>&1 | while IFS= read -r line; do
        echo "[$(ts)] $line" >> "$LOG"
    done
EXIT=${PIPESTATUS[0]}
log "claude finished (exit $EXIT)"

# Remove the completed task from in-progress
grep -vF "$TASK" "$IN_PROGRESS" > "$IN_PROGRESS.tmp" && mv "$IN_PROGRESS.tmp" "$IN_PROGRESS"
