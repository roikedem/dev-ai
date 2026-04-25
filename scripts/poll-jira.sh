#!/usr/bin/env bash
# Polls Jira for actionable issues and pushes tasks to the project queue.
# Runs every 5 min via cron — no Claude involvement.
# Usage: poll-jira.sh <project-dir>

PROJECT_DIR="${1:?Usage: poll-jira.sh <project-dir>}"
DEV_AI_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="$PROJECT_DIR/.jira-process.json"
QUEUE_SH="$DEV_AI_ROOT/scripts/queue.sh"
SEEN_FILE="$PROJECT_DIR/.claude-jira-seen.json"
LOG="$PROJECT_DIR/logs/poll-jira.log"

export PATH="$HOME/.local/bin:/usr/local/bin:$PATH"

mkdir -p "$PROJECT_DIR/logs"
ts()  { date '+%Y-%m-%d %H:%M:%S'; }
log() { echo "[$(ts)] $*" >> "$LOG"; }

[ -f "$CONFIG" ] || { log "missing $CONFIG"; exit 1; }

API_TOKEN_FILE="$HOME/.config/atlassian-api-token"
[ -f "$API_TOKEN_FILE" ] || { log "missing $API_TOKEN_FILE"; exit 1; }
API_TOKEN=$(cat "$API_TOKEN_FILE")

CLOUD_ID=$(jq -r '.jira_cloud_id' "$CONFIG")
PROJECT_KEY=$(jq -r '.jira_project_key' "$CONFIG")
ASSIGNEE=$(jq -r '.jira_assignee' "$CONFIG")
EMAIL="roikedem+claudecode@gmail.com"

BASE_URL="https://intotodev.atlassian.net/rest/api/3"

# Load seen items (issue keys + comment IDs already queued)
if [ -f "$SEEN_FILE" ]; then
    SEEN=$(cat "$SEEN_FILE")
else
    SEEN="{}"
fi

seen_key() { echo "$SEEN" | jq -r --arg k "$1" '.[$k] // "no"'; }
mark_seen() { SEEN=$(echo "$SEEN" | jq --arg k "$1" --arg v "$2" '.[$k] = $v'); }

ADDED=0

# --- Fetch open issues assigned to Claude agent ---
JQL="project=$PROJECT_KEY AND assignee=\"$ASSIGNEE\" AND statusCategory != Done ORDER BY updated DESC"
ENCODED_JQL=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))" "$JQL")

RESPONSE=$(curl -sf -u "$EMAIL:$API_TOKEN" -H "Accept: application/json" \
    "$BASE_URL/search/jql?jql=$ENCODED_JQL&maxResults=20&fields=summary,status,comment")

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
    STATUS_CAT=$(echo "$issue" | jq -r '.fields.status.statusCategory.key')

    # Queue the issue itself if not seen
    if [ "$(seen_key "issue:$KEY")" = "no" ]; then
        TASK=$(jq -nc \
            --arg type "jira_issue" \
            --arg key "$KEY" \
            --arg summary "$SUMMARY" \
            --arg status "$STATUS" \
            --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
            '{type:$type, key:$key, summary:$summary, status:$status, queued_at:$ts}')
        "$QUEUE_SH" push "$PROJECT_DIR" "$TASK"
        mark_seen "issue:$KEY" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
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
        SEEN_KEY="comment:$KEY:$COMMENT_ID"
        if [ "$(seen_key "$SEEN_KEY")" = "no" ]; then
            TASK=$(jq -nc \
                --arg type "jira_comment" \
                --arg key "$KEY" \
                --arg comment_id "$COMMENT_ID" \
                --arg author "$COMMENT_AUTHOR" \
                --arg body "$COMMENT_BODY" \
                --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
                '{type:$type, key:$key, comment_id:$comment_id, author:$author, body:$body, queued_at:$ts}')
            "$QUEUE_SH" push "$PROJECT_DIR" "$TASK"
            mark_seen "$SEEN_KEY" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
            log "queued comment $COMMENT_ID on $KEY by $COMMENT_AUTHOR"
            ADDED=$((ADDED + 1))
        fi
    done <<< "$COMMENTS"

done <<< "$ISSUES"

# Persist seen state
echo "$SEEN" > "$SEEN_FILE"

TOTAL=$("$QUEUE_SH" count "$PROJECT_DIR")
[ $ADDED -gt 0 ] && log "added $ADDED tasks — queue now has $TOTAL"
exit 0
