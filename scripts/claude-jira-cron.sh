#!/usr/bin/env bash

REPO_ROOT="${1:?Usage: claude-jira-cron.sh <project-dir>}"
DEV_AI_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LOCK="$REPO_ROOT/.claude-jira.lock"
LOG="$REPO_ROOT/logs/claude-jira.log"

ts()  { date '+%Y-%m-%d %H:%M:%S'; }
log() { echo "[$(ts)] $*" >> "$LOG"; }

mkdir -p "$REPO_ROOT/logs"
cd "$REPO_ROOT"

# Cron has a minimal PATH — extend it with common user install locations
export PATH="$HOME/.local/bin:/usr/local/bin:$PATH"

# Ensure gh operates as the Claude agent account, not the user's account
gh auth switch --user ClaudeCodeRoiAgent 2>/dev/null || log "warning: could not switch gh to ClaudeCodeRoiAgent"

CLAUDE=$(which claude 2>/dev/null)
if [ -z "$CLAUDE" ]; then
    log "claude not found in PATH"
    exit 1
fi

exec 9>"$LOCK"
if ! flock -n 9; then
    log "skipped — lock held by another instance"
    exit 0
fi

log "starting claude ($CLAUDE)"
"$CLAUDE" --dangerously-skip-permissions \
    -p "Follow the Entry Point section in $DEV_AI_ROOT/JIRA-PROCESS.md." \
    2>&1 | while IFS= read -r line; do
        echo "[$(ts)] $line" >> "$LOG"
    done
EXIT=${PIPESTATUS[0]}
log "claude finished (exit $EXIT)"
