#!/usr/bin/env bash
# Reads ~/.config/dev-ai.json and runs a given script for each enabled project.
# Usage: for-all-projects.sh <script-name>
# Example crontab:
#   */5 * * * * ~/projects/dev-ai/scripts/for-all-projects.sh poll-jira.sh
#   */5 * * * * ~/projects/dev-ai/scripts/for-all-projects.sh poll-github.sh
#   */5 * * * * ~/projects/dev-ai/scripts/for-all-projects.sh claude-jira-cron.sh

SCRIPT="${1:?Usage: for-all-projects.sh <script-name>}"
CONFIG="$HOME/.config/dev-ai.json"
DEV_AI_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

[ -f "$CONFIG" ] || { echo "missing $CONFIG" >&2; exit 1; }

jq -r '.projects[] | select(.enabled == true) | .dir' "$CONFIG" | while IFS= read -r dir; do
    "$DEV_AI_ROOT/scripts/$SCRIPT" "$dir"
done
