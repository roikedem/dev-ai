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

API_TOKEN_FILE="$HOME/.config/atlassian-api-token"
[ -f "$API_TOKEN_FILE" ] || { log "missing $API_TOKEN_FILE"; exit 1; }
API_TOKEN=$(cat "$API_TOKEN_FILE" | tr -d '\r\n')

CLOUD_ID=$(jq -r '.jira_cloud_id' "$CONFIG")
PROJECT_KEY=$(jq -r '.jira_project_key' "$CONFIG")
EMAIL="roikedem+claudecode@gmail.com"

BASE_URL="https://intotodev.atlassian.net/rest/api/3"

# Resolve the agent's OWN accountId from the credentials we authenticate with.
# Everything downstream scopes to this id, so the pipeline can only ever see and
# act on its own tasks — never one assigned to Roi (e.g. KNS-228) or anyone else.
SELF_ID=$(curl -sf -u "$EMAIL:$API_TOKEN" -H "Accept: application/json" \
    "$BASE_URL/myself" | jq -r '.accountId // ""')
if [ -z "$SELF_ID" ]; then
    log "refusing to poll: could not resolve agent accountId from /myself"
    exit 1
fi

ISSUES_SEEN=0
ISSUES_NEW=0
COMMENTS_SEEN=0
COMMENTS_NEW=0

# --- Fetch open issues assigned to the agent itself ---
# assignee = currentUser() resolves server-side to the authenticated account, so
# this is impossible to misconfigure into matching someone else's tasks.
JQL="project=$PROJECT_KEY AND assignee = currentUser() AND statusCategory != Done ORDER BY updated DESC"
ENCODED_JQL=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))" "$JQL")

RESPONSE=$(curl -sf -u "$EMAIL:$API_TOKEN" -H "Accept: application/json" \
    "$BASE_URL/search/jql?jql=$ENCODED_JQL&maxResults=20&fields=summary,status,assignee,comment")

if [ $? -ne 0 ]; then
    log "Jira API request failed"
    exit 1
fi

ISSUES_SEEN=$(echo "$RESPONSE" | jq '(.issues // []) | length')
ISSUES=$(echo "$RESPONSE" | jq -c '.issues[]')

while IFS= read -r issue; do
    [ -z "$issue" ] && continue

    KEY=$(echo "$issue" | jq -r '.key')
    SUMMARY=$(echo "$issue" | jq -r '.fields.summary')
    STATUS=$(echo "$issue" | jq -r '.fields.status.name')

    # Defense in depth: never queue an issue that isn't actually assigned to the
    # agent, even if the JQL above is ever loosened or wrong. This is the guard
    # that would have kept a Roi-assigned task (e.g. KNS-228) out of the pipeline.
    ISSUE_ASSIGNEE=$(echo "$issue" | jq -r '.fields.assignee.accountId // ""')
    if [ "$ISSUE_ASSIGNEE" != "$SELF_ID" ]; then
        log "SKIP $KEY: assignee '$ISSUE_ASSIGNEE' is not the agent — not queuing"
        continue
    fi

    TASK=$(jq -nc \
        --arg type "jira_issue" \
        --arg key "$KEY" \
        --arg summary "$SUMMARY" \
        --arg status "$STATUS" \
        --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{type:$type, key:$key, summary:$summary, status:$status, queued_at:$ts}')
    INSERTED=$("$QUEUE_SH" push "$PROJECT_DIR" "$TASK" "issue:$KEY")
    if [ "$INSERTED" = "1" ]; then
        log "queued issue $KEY: $SUMMARY"
        ISSUES_NEW=$((ISSUES_NEW + 1))
    fi

    # Queue any new comments on this issue (comments from humans, not from the agent).
    # Filter by the agent's own accountId — reliable even if Jira anonymizes names.
    COMMENTS=$(echo "$issue" | jq -c --arg id "$SELF_ID" '.fields.comment.comments[]? | select(.author.accountId != $id)')
    while IFS= read -r comment; do
        [ -z "$comment" ] && continue
        COMMENTS_SEEN=$((COMMENTS_SEEN + 1))
        COMMENT_ID=$(echo "$comment" | jq -r '.id')
        COMMENT_BODY=$(echo "$comment" | jq -r '.body' | head -c 200)
        COMMENT_AUTHOR=$(echo "$comment" | jq -r '.author.displayName')
        TASK=$(jq -nc \
            --arg type "jira_comment" \
            --arg key "$KEY" \
            --arg comment_id "$COMMENT_ID" \
            --arg author "$COMMENT_AUTHOR" \
            --arg body "$COMMENT_BODY" \
            --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
            '{type:$type, key:$key, comment_id:$comment_id, author:$author, body:$body, queued_at:$ts}')
        INSERTED=$("$QUEUE_SH" push "$PROJECT_DIR" "$TASK" "comment:$KEY:$COMMENT_ID")
        if [ "$INSERTED" = "1" ]; then
            log "queued comment $COMMENT_ID on $KEY by $COMMENT_AUTHOR"
            COMMENTS_NEW=$((COMMENTS_NEW + 1))
        fi
    done <<< "$COMMENTS"

done <<< "$ISSUES"

TOTAL=$("$QUEUE_SH" count "$PROJECT_DIR")
log "polled: $ISSUES_SEEN issues ($ISSUES_NEW new), $COMMENTS_SEEN comments ($COMMENTS_NEW new) — queue=$TOTAL"
exit 0
