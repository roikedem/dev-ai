#!/usr/bin/env bash
# Reads ~/.config/dev-ai.json and runs a given script for each enabled project.
# Usage: for-all-projects.sh <script-name>
# Example crontab:
#   */5 * * * * ~/projects/dev-ai/scripts/for-all-projects.sh poll-jira.sh
#   */5 * * * * ~/projects/dev-ai/scripts/for-all-projects.sh poll-github.sh
#   */5 * * * * ~/projects/dev-ai/scripts/for-all-projects.sh claude-jira-cron.sh
#
# Projects run in PARALLEL, not one after another. This used to be a blocking
# loop, which meant claude-jira-cron.sh — a call that occupies a whole Claude
# session and can run for many minutes — held every later project hostage until
# it finished; with several projects wired in, the last one in the list could
# starve. Each project is independent (its own queue rows, its own repo, its own
# .claude-jira.lock), so there is nothing to serialise. The per-project lock,
# not this loop, is what prevents two runs of the same project overlapping.

SCRIPT="${1:?Usage: for-all-projects.sh <script-name>}"
CONFIG="$HOME/.config/dev-ai.json"
DEV_AI_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

[ -f "$CONFIG" ] || { echo "missing $CONFIG" >&2; exit 1; }

PIDS=""
while IFS= read -r dir; do
    "$DEV_AI_ROOT/scripts/$SCRIPT" "$dir" &
    PIDS="$PIDS $!"
done < <(jq -r '.projects[] | select(.enabled == true) | .dir' "$CONFIG")

# Wait for all projects so cron sees one run per tick rather than an immediate
# exit leaving orphans, and so a non-zero project exit still surfaces.
STATUS=0
for pid in $PIDS; do
    wait "$pid" || STATUS=1
done
exit $STATUS
