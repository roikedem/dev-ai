#!/usr/bin/env bash
# Polls Jira for actionable issues and pushes tasks to the project queue.
# Runs every 5 min via cron — no Claude involvement.
# Usage: poll-jira.sh <project-dir>

PROJECT_DIR="${1:?Usage: poll-jira.sh <project-dir>}"
DEV_AI_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="$PROJECT_DIR/.jira-process.json"
QUEUE_SH="$DEV_AI_ROOT/scripts/queue.sh"
LOG="$PROJECT_DIR/logs/poll-jira.log"

export PATH="$HOME/.local/bin:/usr/local/bin:$PATH"

mkdir -p "$PROJECT_DIR/logs"
ts()  { date '+%Y-%m-%d %H:%M:%S'; }
log() { echo "[$(ts)] $*" >> "$LOG"; }

[ -f "$CONFIG" ] || { log "missing $CONFIG"; exit 1; }

API_TOKEN_FILE="$HOME/.config/atlassian-api-token-admin"
[ -f "$API_TOKEN_FILE" ] || { log "missing $API_TOKEN_FILE"; exit 1; }
API_TOKEN=$(cat "$API_TOKEN_FILE" | tr -d '\r\n')

CLOUD_ID=$(jq -r '.jira_cloud_id' "$CONFIG")
PROJECT_KEY=$(jq -r '.jira_project_key' "$CONFIG")
ASSIGNEE=$(jq -r '.jira_assignee' "$CONFIG")
EMAIL="roikedem+admin@gmail.com"

BASE_URL="https://intotodev.atlassian.net/rest/api/3"

ADDED=0

# --- Fetch open issues assigned to Claude agent ---
JQL="project=$PROJECT_KEY AND assignee=\"$ASSIGNEE\" AND statusCategory != Done ORDER BY updated DESC"
ENCODED_JQL=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))" "$JQL")

RESPONSE=$(curl -sf -u "$EMAIL:$API_TOKEN" -H "Accept: application/json" \
    "$BASE_URL/search/jql?jql=$ENCODED_JQL&maxResults=20&fields=summary,status,comment,labels")

if [ $? -ne 0 ]; then
    log "Jira API request failed"
    exit 1
fi

ISSUES=$(echo "$RESPONSE" | jq -c '.issues[]')

while IFS= read -r issue; do
    [ -z "$issue" ] && continue

    KEY=$(echo "$issue" | jq -r '.key')
    SUMMARY=$(echo "$issue" | jq -r '.fields.summary')
    STATUS=$(echo "$issue" | jq -r '.fields.status.name')
    LABELS=$(echo "$issue" | jq -c '.fields.labels // []')

    # Only local agents handle issues with local-dev-env or local-test-env labels.
    # Cloud agent handles everything else — skip those here.
    HAS_LOCAL=$(echo "$LABELS" | jq -r 'map(select(. == "local-dev-env" or . == "local-test-env")) | length > 0')
    if [ "$HAS_LOCAL" != "true" ]; then
        continue
    fi

    TASK=$(jq -nc \
        --arg type "jira_issue" \
        --arg key "$KEY" \
        --arg summary "$SUMMARY" \
        --arg status "$STATUS" \
        --argjson labels "$LABELS" \
        --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{type:$type, key:$key, summary:$summary, status:$status, labels:$labels, queued_at:$ts}')
    INSERTED=$("$QUEUE_SH" push "$PROJECT_DIR" "$TASK" "issue:$KEY")
    if [ "$INSERTED" = "1" ]; then
        log "queued issue $KEY: $SUMMARY"
        ADDED=$((ADDED + 1))
    fi

    # Queue any new comments on this issue (comments from humans, not from Claude agent)
    COMMENTS=$(echo "$issue" | jq -c '.fields.comment.comments[]? | select(.author.displayName != "'"$ASSIGNEE"'")')
    while IFS= read -r comment; do
        [ -z "$comment" ] && continue
        COMMENT_ID=$(echo "$comment" | jq -r '.id')
        COMMENT_BODY=$(echo "$comment" | jq -r '.body' | head -c 200)
        COMMENT_AUTHOR=$(echo "$comment" | jq -r '.author.displayName')
        TASK=$(jq -nc \
            --arg type "jira_comment" \
            --arg key "$KEY" \
            --arg comment_id "$COMMENT_ID" \
            --arg author "$COMMENT_AUTHOR" \
            --arg body "$COMMENT_BODY" \
            --argjson labels "$LABELS" \
            --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
            '{type:$type, key:$key, comment_id:$comment_id, author:$author, body:$body, labels:$labels, queued_at:$ts}')
        INSERTED=$("$QUEUE_SH" push "$PROJECT_DIR" "$TASK" "comment:$KEY:$COMMENT_ID")
        if [ "$INSERTED" = "1" ]; then
            log "queued comment $COMMENT_ID on $KEY by $COMMENT_AUTHOR"
            ADDED=$((ADDED + 1))
        fi
    done <<< "$COMMENTS"

done <<< "$ISSUES"

TOTAL=$("$QUEUE_SH" count "$PROJECT_DIR")
[ $ADDED -gt 0 ] && log "added $ADDED tasks — queue now has $TOTAL"
exit 0
