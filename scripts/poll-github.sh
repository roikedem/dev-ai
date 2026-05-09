#!/usr/bin/env bash
# Polls GitHub for new PR review comments and pushes tasks to the project queue.
# Runs every 5 min via cron — no Claude involvement.
# Usage: poll-github.sh <project-dir>

PROJECT_DIR="${1:?Usage: poll-github.sh <project-dir>}"
DEV_AI_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="$PROJECT_DIR/.jira-process.json"
QUEUE_SH="$DEV_AI_ROOT/scripts/queue.sh"
LOG="$PROJECT_DIR/logs/poll-github.log"

export PATH="$HOME/.local/bin:/usr/local/bin:$PATH"

mkdir -p "$PROJECT_DIR/logs"
ts()  { date '+%Y-%m-%d %H:%M:%S'; }
log() { echo "[$(ts)] $*" >> "$LOG"; }

[ -f "$CONFIG" ] || { log "missing $CONFIG"; exit 1; }

AGENT_TOKEN_FILE="$HOME/.config/claude-agent-gh-token"
[ -f "$AGENT_TOKEN_FILE" ] || { log "missing $AGENT_TOKEN_FILE"; exit 1; }
export GH_TOKEN=$(cat "$AGENT_TOKEN_FILE")

AGENT_DISPLAY="ClaudeCodeRoiAgent"

# Jira credentials for label checking (only queue PRs tied to local-dev-env issues)
JIRA_EMAIL="roikedem+admin@gmail.com"
JIRA_TOKEN_FILE="$HOME/.config/atlassian-api-token-admin"
JIRA_TOKEN=""
JIRA_BASE_URL="https://intotodev.atlassian.net/rest/api/3"
[ -f "$JIRA_TOKEN_FILE" ] && JIRA_TOKEN=$(cat "$JIRA_TOKEN_FILE" | tr -d '\r\n')

# Cache: associative array JIRA_KEY -> "1" (has local-dev-env) or "0" (does not)
declare -A _LABEL_CACHE

# Returns 0 (true) if the Jira issue has local-dev-env label, 1 (false) otherwise.
# Falls back to "include" when Jira is unreachable, to avoid silently dropping tasks.
has_local_dev_label() {
    local KEY="$1"
    [ -z "$KEY" ] && return 1
    if [[ -v _LABEL_CACHE["$KEY"] ]]; then
        [ "${_LABEL_CACHE[$KEY]}" = "1" ] && return 0 || return 1
    fi
    if [ -z "$JIRA_TOKEN" ]; then
        _LABEL_CACHE["$KEY"]="1"; return 0  # no credentials — include to be safe
    fi
    local RESP
    RESP=$(curl -sf -u "$JIRA_EMAIL:$JIRA_TOKEN" -H "Accept: application/json" \
        "$JIRA_BASE_URL/issue/$KEY?fields=labels" 2>/dev/null)
    if echo "$RESP" | jq -e '[.fields.labels[]?] | contains(["local-dev-env"])' > /dev/null 2>&1; then
        _LABEL_CACHE["$KEY"]="1"; return 0
    else
        _LABEL_CACHE["$KEY"]="0"; return 1
    fi
}

# Build list of repos to poll from the repos array
mapfile -t REPOS < <(jq -r '.repos[].github' "$CONFIG")

ADDED=0

poll_repo() {
    local REPO="$1"

    # Fetch open PRs
    local OPEN_PRS
    OPEN_PRS=$(gh api "repos/$REPO/pulls?state=open&per_page=20" 2>/dev/null)
    if [ $? -ne 0 ]; then
        log "gh API request failed for $REPO"
        return 1
    fi

    local PR_NUMBERS
    PR_NUMBERS=$(echo "$OPEN_PRS" | jq -r '.[].number')

    while IFS= read -r PR_NUM; do
        [ -z "$PR_NUM" ] && continue

        local PR_TITLE PR_BRANCH
        PR_TITLE=$(echo "$OPEN_PRS" | jq -r --argjson n "$PR_NUM" '.[] | select(.number==$n) | .title')
        PR_BRANCH=$(echo "$OPEN_PRS" | jq -r --argjson n "$PR_NUM" '.[] | select(.number==$n) | .head.ref')

        # Only queue events for issues that need local-dev-env handling.
        # Cloud agent handles GitHub feedback on all other PRs.
        local JIRA_KEY_FROM_BRANCH
        JIRA_KEY_FROM_BRANCH=$(echo "$PR_BRANCH" | grep -oE '^[A-Z]+-[0-9]+' || echo "")
        if ! has_local_dev_label "$JIRA_KEY_FROM_BRANCH"; then
            continue
        fi

        # Review comments (inline)
        local COMMENTS HUMAN_COMMENTS
        COMMENTS=$(gh api "repos/$REPO/pulls/$PR_NUM/comments?per_page=50" 2>/dev/null)
        if [ $? -ne 0 ]; then
            log "failed to fetch comments for $REPO PR $PR_NUM"
            continue
        fi
        HUMAN_COMMENTS=$(echo "$COMMENTS" | jq -c --arg agent "$AGENT_DISPLAY" \
            '.[] | select(.user.login != $agent)')

        while IFS= read -r comment; do
            [ -z "$comment" ] && continue
            local COMMENT_ID COMMENT_BODY COMMENT_AUTHOR
            COMMENT_ID=$(echo "$comment" | jq -r '.id')
            COMMENT_BODY=$(echo "$comment" | jq -r '.body' | head -c 300)
            COMMENT_AUTHOR=$(echo "$comment" | jq -r '.user.login')
            local TASK INSERTED
            TASK=$(jq -nc \
                --arg type "github_pr_comment" \
                --arg repo "$REPO" \
                --argjson pr_number "$PR_NUM" \
                --arg pr_title "$PR_TITLE" \
                --arg branch "$PR_BRANCH" \
                --arg comment_id "$COMMENT_ID" \
                --arg author "$COMMENT_AUTHOR" \
                --arg body "$COMMENT_BODY" \
                --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
                '{type:$type, repo:$repo, pr_number:$pr_number, pr_title:$pr_title, branch:$branch, comment_id:$comment_id, author:$author, body:$body, queued_at:$ts}')
            INSERTED=$("$QUEUE_SH" push "$PROJECT_DIR" "$TASK" "pr-comment:$REPO:$PR_NUM:$COMMENT_ID")
            if [ "$INSERTED" = "1" ]; then
                log "queued $REPO PR #$PR_NUM comment $COMMENT_ID by $COMMENT_AUTHOR"
                ADDED=$((ADDED + 1))
            fi
        done <<< "$HUMAN_COMMENTS"

        # Top-level PR thread comments (issue comments endpoint)
        local THREAD_COMMENTS HUMAN_THREAD
        THREAD_COMMENTS=$(gh api "repos/$REPO/issues/$PR_NUM/comments?per_page=50" 2>/dev/null)
        HUMAN_THREAD=$(echo "$THREAD_COMMENTS" | jq -c --arg agent "$AGENT_DISPLAY" \
            '.[] | select(.user.login != $agent) | select(.user.type != "Bot")')

        while IFS= read -r comment; do
            [ -z "$comment" ] && continue
            local COMMENT_ID COMMENT_BODY COMMENT_AUTHOR
            COMMENT_ID=$(echo "$comment" | jq -r '.id')
            COMMENT_BODY=$(echo "$comment" | jq -r '.body' | head -c 300)
            COMMENT_AUTHOR=$(echo "$comment" | jq -r '.user.login')
            local TASK INSERTED
            TASK=$(jq -nc \
                --arg type "github_pr_comment" \
                --arg repo "$REPO" \
                --argjson pr_number "$PR_NUM" \
                --arg pr_title "$PR_TITLE" \
                --arg branch "$PR_BRANCH" \
                --arg comment_id "$COMMENT_ID" \
                --arg author "$COMMENT_AUTHOR" \
                --arg body "$COMMENT_BODY" \
                --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
                '{type:$type, repo:$repo, pr_number:$pr_number, pr_title:$pr_title, branch:$branch, comment_id:$comment_id, author:$author, body:$body, queued_at:$ts}')
            INSERTED=$("$QUEUE_SH" push "$PROJECT_DIR" "$TASK" "pr-thread-comment:$REPO:$PR_NUM:$COMMENT_ID")
            if [ "$INSERTED" = "1" ]; then
                log "queued $REPO PR #$PR_NUM thread comment $COMMENT_ID by $COMMENT_AUTHOR"
                ADDED=$((ADDED + 1))
            fi
        done <<< "$HUMAN_THREAD"

        # Reviews (CHANGES_REQUESTED / APPROVED)
        local REVIEWS HUMAN_REVIEWS
        REVIEWS=$(gh api "repos/$REPO/pulls/$PR_NUM/reviews?per_page=20" 2>/dev/null)
        HUMAN_REVIEWS=$(echo "$REVIEWS" | jq -c --arg agent "$AGENT_DISPLAY" \
            '.[] | select(.user.login != $agent) | select(.state == "CHANGES_REQUESTED" or .state == "APPROVED")')

        while IFS= read -r review; do
            [ -z "$review" ] && continue
            local REVIEW_ID REVIEW_STATE REVIEW_BODY REVIEW_AUTHOR
            REVIEW_ID=$(echo "$review" | jq -r '.id')
            REVIEW_STATE=$(echo "$review" | jq -r '.state')
            REVIEW_BODY=$(echo "$review" | jq -r '.body' | head -c 300)
            REVIEW_AUTHOR=$(echo "$review" | jq -r '.user.login')
            local TASK INSERTED
            TASK=$(jq -nc \
                --arg type "github_pr_review" \
                --arg repo "$REPO" \
                --argjson pr_number "$PR_NUM" \
                --arg pr_title "$PR_TITLE" \
                --arg branch "$PR_BRANCH" \
                --arg review_id "$REVIEW_ID" \
                --arg state "$REVIEW_STATE" \
                --arg author "$REVIEW_AUTHOR" \
                --arg body "$REVIEW_BODY" \
                --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
                '{type:$type, repo:$repo, pr_number:$pr_number, pr_title:$pr_title, branch:$branch, review_id:$review_id, state:$state, author:$author, body:$body, queued_at:$ts}')
            INSERTED=$("$QUEUE_SH" push "$PROJECT_DIR" "$TASK" "pr-review:$REPO:$PR_NUM:$REVIEW_ID")
            if [ "$INSERTED" = "1" ]; then
                log "queued $REPO PR #$PR_NUM $REVIEW_STATE review by $REVIEW_AUTHOR"
                ADDED=$((ADDED + 1))
            fi
        done <<< "$HUMAN_REVIEWS"

    done <<< "$PR_NUMBERS"

    # Recently merged PRs (last hour)
    local MERGED_PRS
    MERGED_PRS=$(gh api "repos/$REPO/pulls?state=closed&per_page=10" 2>/dev/null | \
        jq -c '.[] | select(.merged_at != null) | select(.merged_at > (now - 3600 | todate))')
    while IFS= read -r pr; do
        [ -z "$pr" ] && continue
        local MERGED_PR_NUM MERGED_TITLE MERGED_BRANCH
        MERGED_PR_NUM=$(echo "$pr" | jq -r '.number')
        MERGED_TITLE=$(echo "$pr" | jq -r '.title')
        MERGED_BRANCH=$(echo "$pr" | jq -r '.head.ref')

        local MERGED_JIRA_KEY
        MERGED_JIRA_KEY=$(echo "$MERGED_BRANCH" | grep -oE '^[A-Z]+-[0-9]+' || echo "")
        if ! has_local_dev_label "$MERGED_JIRA_KEY"; then
            continue
        fi
        local TASK INSERTED
        TASK=$(jq -nc \
            --arg type "github_pr_merged" \
            --arg repo "$REPO" \
            --argjson pr_number "$MERGED_PR_NUM" \
            --arg pr_title "$MERGED_TITLE" \
            --arg branch "$MERGED_BRANCH" \
            --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
            '{type:$type, repo:$repo, pr_number:$pr_number, pr_title:$pr_title, branch:$branch, queued_at:$ts}')
        INSERTED=$("$QUEUE_SH" push "$PROJECT_DIR" "$TASK" "pr-merged:$REPO:$MERGED_PR_NUM")
        if [ "$INSERTED" = "1" ]; then
            log "queued merged $REPO PR #$MERGED_PR_NUM: $MERGED_TITLE"
            ADDED=$((ADDED + 1))
        fi
    done <<< "$MERGED_PRS"
}

for REPO in "${REPOS[@]}"; do
    poll_repo "$REPO"
done

TOTAL=$("$QUEUE_SH" count "$PROJECT_DIR")
[ $ADDED -gt 0 ] && log "added $ADDED tasks — queue now has $TOTAL"
exit 0
