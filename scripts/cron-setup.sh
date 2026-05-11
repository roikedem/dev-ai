#!/usr/bin/env bash
set -euo pipefail

# One-time machine setup for a target project.
# Usage:
#   ~/projects/dev-ai/scripts/cron-setup.sh /path/to/project

PROJECT_DIR="${1:?Usage: cron-setup.sh <project-dir>}"
DEV_AI_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

mkdir -p "$PROJECT_DIR/logs" "$PROJECT_DIR/docs/screenshots"
touch "$PROJECT_DIR/.gitignore"

ensure_gitignore_line() {
  local line="$1"
  grep -qxF "$line" "$PROJECT_DIR/.gitignore" || echo "$line" >> "$PROJECT_DIR/.gitignore"
}

ensure_gitignore_line "logs/"
ensure_gitignore_line ".claude-jira.lock"
ensure_gitignore_line ".claude-jira-last-active"
ensure_gitignore_line ".claude-queue.jsonl"
ensure_gitignore_line ".claude-jira-seen.json"
ensure_gitignore_line ".claude-gh-seen.json"
ensure_gitignore_line ".claude-queue.lock"

chmod +x \
  "$DEV_AI_ROOT/scripts/claude-jira-cron.sh" \
  "$DEV_AI_ROOT/scripts/poll-jira.sh" \
  "$DEV_AI_ROOT/scripts/poll-github.sh" \
  "$DEV_AI_ROOT/scripts/queue.sh" \
  "$DEV_AI_ROOT/scripts/session-setup.sh" \
  "$DEV_AI_ROOT/scripts/cron-setup.sh"

# gh auth switch is best-effort — scripts use GH_TOKEN env var directly
if command -v gh >/dev/null 2>&1; then
  gh auth switch --user ClaudeCodeRoiAgent >/dev/null 2>&1 \
    && echo "Switched gh auth to user ClaudeCodeRoiAgent" \
    || echo "Note: gh auth switch skipped — scripts use GH_TOKEN env var directly"
fi

# Load nvm so npm is available (nvm is not active in all shell contexts)
export NVM_DIR="$HOME/.nvm"
set +eu
[ -s "$NVM_DIR/nvm.sh" ] && source "$NVM_DIR/nvm.sh"
set -eu

if [ -f "$DEV_AI_ROOT/package.json" ]; then
  if command -v npm >/dev/null 2>&1; then
    (cd "$DEV_AI_ROOT" && npm install puppeteer)
  else
    echo "Warning: npm not found; install Node.js via nvm then re-run this script." >&2
  fi
else
  echo "Warning: package.json not found in $DEV_AI_ROOT; skipped npm install puppeteer" >&2
fi

echo
echo "Add these lines to crontab (crontab -e):"
echo "*/5 * * * * $DEV_AI_ROOT/scripts/poll-jira.sh $PROJECT_DIR"
echo "*/5 * * * * $DEV_AI_ROOT/scripts/poll-github.sh $PROJECT_DIR"
echo "*/5 * * * * $DEV_AI_ROOT/scripts/claude-jira-cron.sh $PROJECT_DIR"