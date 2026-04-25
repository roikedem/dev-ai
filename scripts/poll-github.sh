#!/usr/bin/env bash
# Polls GitHub for new PR review comments and pushes tasks to the project queue.
# Runs every 5 min via cron — no Claude involvement.
# Usage: poll-github.sh <project-dir>

PROJECT_DIR="${1:?Usage: poll-github.sh <project-dir>}"
DEV_AI_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="$PROJECT_DIR/.jira-process.json"
QUEUE_SH="$DEV_AI_ROOT/scripts/queue.sh"
SEEN_FILE="$PROJECT_DIR/.claude-gh-seen.json"
LOG="$PROJECT_DIR/logs/poll-github.log"

export PATH="$HOME/.local/bin:/usr/local/bin:$PATH"

mkdir -p "$PROJECT_DIR/logs"
ts()  { date '+%Y-%m-%d %H:%M:%S'; }
log() { echo "[$(ts)] $*" >> "$LOG"; }

[ -f "$CONFIG" ] || { log "missing $CONFIG"; exit 1; }

AGENT_TOKEN_FILE="$HOME/.config/claude-agent-gh-token"
[ -f "$AGENT_TOKEN_FILE" ] || { log "missing $AGENT_TOKEN_FILE"; exit 1; }
export GH_TOKEN=$(cat "$AGENT_TOKEN_FILE")

GITHUB_REPO=$(jq -r '.github_repo' "$CONFIG")
AGENT_DISPLAY="ClaudeCodeRoiAgent"

# Load seen items
if [ -f "$SEEN_FILE" ]; then
    SEEN=$(cat "$SEEN_FILE")
else
    SEEN="{}"
fi

seen_key() { echo "$SEEN" | jq -r --arg k "$1" '.[$k] // "no"'; }
mark_seen() { SEEN=$(echo "$SEEN" | jq --arg k "$1" --arg v "$2" '.[$k] = $v'); }

ADDED=0

# Fetch open PRs
OPEN_PRS=$(gh api "repos/$GITHUB_REPO/pulls?state=open&per_page=20" 2>/dev/null)
if [ $? -ne 0 ]; then
    log "gh API request failed for $GITHUB_REPO"
    exit 1
fi

PR_NUMBERS=$(echo "$OPEN_PRS" | jq -r '.[].number')

while IFS= read -r PR_NUM; do
    [ -z "$PR_NUM" ] && continue

    PR_TITLE=$(echo "$OPEN_PRS" | jq -r --argjson n "$PR_NUM" '.[] | select(.number==$n) | .title')
    PR_BRANCH=$(echo "$OPEN_PRS" | jq -r --argjson n "$PR_NUM" '.[] | select(.number==$n) | .head.ref')

    # Fetch review comments on this PR
    COMMENTS=$(gh api "repos/$GITHUB_REPO/pulls/$PR_NUM/comments?per_page=50" 2>/dev/null)
    if [ $? -ne 0 ]; then
        log "failed to fetch comments for PR $PR_NUM"
        continue
    fi

    # Only comments NOT from the Claude agent
    HUMAN_COMMENTS=$(echo "$COMMENTS" | jq -c --arg agent "$AGENT_DISPLAY" \
        '.[] | select(.user.login != $agent)')

    while IFS= read -r comment; do
        [ -z "$comment" ] && continue
        COMMENT_ID=$(echo "$comment" | jq -r '.id')
        COMMENT_BODY=$(echo "$comment" | jq -r '.body' | head -c 300)
        COMMENT_AUTHOR=$(echo "$comment" | jq -r '.user.login')
        SEEN_KEY="pr-comment:$PR_NUM:$COMMENT_ID"

        if [ "$(seen_key "$SEEN_KEY")" = "no" ]; then
            TASK=$(jq -nc \
                --arg type "github_pr_comment" \
                --argjson pr_number "$PR_NUM" \
                --arg pr_title "$PR_TITLE" \
                --arg branch "$PR_BRANCH" \
                --arg comment_id "$COMMENT_ID" \
                --arg author "$COMMENT_AUTHOR" \
                --arg body "$COMMENT_BODY" \
                --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
                '{type:$type, pr_number:$pr_number, pr_title:$pr_title, branch:$branch, comment_id:$comment_id, author:$author, body:$body, queued_at:$ts}')
            "$QUEUE_SH" push "$PROJECT_DIR" "$TASK"
            mark_seen "$SEEN_KEY" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
            log "queued PR #$PR_NUM comment $COMMENT_ID by $COMMENT_AUTHOR"
            ADDED=$((ADDED + 1))
        fi
    done <<< "$HUMAN_COMMENTS"

    # Fetch general (issue-level) PR comments (reviews)
    REVIEWS=$(gh api "repos/$GITHUB_REPO/pulls/$PR_NUM/reviews?per_page=20" 2>/dev/null)
    HUMAN_REVIEWS=$(echo "$REVIEWS" | jq -c --arg agent "$AGENT_DISPLAY" \
        '.[] | select(.user.login != $agent) | select(.state == "CHANGES_REQUESTED" or .state == "APPROVED")')

    while IFS= read -r review; do
        [ -z "$review" ] && continue
        REVIEW_ID=$(echo "$review" | jq -r '.id')
        REVIEW_STATE=$(echo "$review" | jq -r '.state')
        REVIEW_BODY=$(echo "$review" | jq -r '.body' | head -c 300)
        REVIEW_AUTHOR=$(echo "$review" | jq -r '.user.login')
        SEEN_KEY="pr-review:$PR_NUM:$REVIEW_ID"

        if [ "$(seen_key "$SEEN_KEY")" = "no" ]; then
            TASK=$(jq -nc \
                --arg type "github_pr_review" \
                --argjson pr_number "$PR_NUM" \
                --arg pr_title "$PR_TITLE" \
                --arg branch "$PR_BRANCH" \
                --arg review_id "$REVIEW_ID" \
                --arg state "$REVIEW_STATE" \
                --arg author "$REVIEW_AUTHOR" \
                --arg body "$REVIEW_BODY" \
                --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
                '{type:$type, pr_number:$pr_number, pr_title:$pr_title, branch:$branch, review_id:$review_id, state:$state, author:$author, body:$body, queued_at:$ts}')
            "$QUEUE_SH" push "$PROJECT_DIR" "$TASK"
            mark_seen "$SEEN_KEY" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
            log "queued PR #$PR_NUM $REVIEW_STATE review by $REVIEW_AUTHOR"
            ADDED=$((ADDED + 1))
        fi
    done <<< "$HUMAN_REVIEWS"

    # Also check for merged PRs (recently merged) that Claude hasn't processed
    MERGED_PRS=$(gh api "repos/$GITHUB_REPO/pulls?state=closed&per_page=10" 2>/dev/null | \
        jq -c '.[] | select(.merged_at != null) | select(.merged_at > (now - 3600 | todate))')
    while IFS= read -r pr; do
        [ -z "$pr" ] && continue
        MERGED_PR_NUM=$(echo "$pr" | jq -r '.number')
        MERGED_TITLE=$(echo "$pr" | jq -r '.title')
        MERGED_BRANCH=$(echo "$pr" | jq -r '.head.ref')
        SEEN_KEY="pr-merged:$MERGED_PR_NUM"
        if [ "$(seen_key "$SEEN_KEY")" = "no" ]; then
            TASK=$(jq -nc \
                --arg type "github_pr_merged" \
                --argjson pr_number "$MERGED_PR_NUM" \
                --arg pr_title "$MERGED_TITLE" \
                --arg branch "$MERGED_BRANCH" \
                --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
                '{type:$type, pr_number:$pr_number, pr_title:$pr_title, branch:$branch, queued_at:$ts}')
            "$QUEUE_SH" push "$PROJECT_DIR" "$TASK"
            mark_seen "$SEEN_KEY" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
            log "queued merged PR #$MERGED_PR_NUM: $MERGED_TITLE"
            ADDED=$((ADDED + 1))
        fi
    done <<< "$MERGED_PRS"

done <<< "$PR_NUMBERS"

# Persist seen state
echo "$SEEN" > "$SEEN_FILE"

TOTAL=$("$QUEUE_SH" count "$PROJECT_DIR")
[ $ADDED -gt 0 ] && log "added $ADDED tasks — queue now has $TOTAL"
exit 0
