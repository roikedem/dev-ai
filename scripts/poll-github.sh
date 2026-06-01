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

    # --- Auto-merge integration-branch PRs when green ---
    # For repos flagged auto_merge_when_green, merge open PRs that target the repo's
    # base_branch (e.g. dev) once required checks are green and nothing is blocking.
    # Safe by design: these PRs target an integration branch that never deploys to
    # production, so the pipeline owns the merge. Promotion dev->master is never touched here.
    local AUTO_MERGE BASE_BRANCH
    AUTO_MERGE=$(jq -r --arg r "$REPO" '.repos[] | select(.github==$r) | .auto_merge_when_green // false' "$CONFIG")
    BASE_BRANCH=$(jq -r --arg r "$REPO" '.repos[] | select(.github==$r) | .base_branch // empty' "$CONFIG")
    if [ "$AUTO_MERGE" = "true" ] && [ -n "$BASE_BRANCH" ]; then
        while IFS= read -r PR_NUM; do
            [ -z "$PR_NUM" ] && continue
            local PR_BASE HEAD_SHA
            PR_BASE=$(echo "$OPEN_PRS" | jq -r --argjson n "$PR_NUM" '.[] | select(.number==$n) | .base.ref')
            [ "$PR_BASE" = "$BASE_BRANCH" ] || continue
            HEAD_SHA=$(echo "$OPEN_PRS" | jq -r --argjson n "$PR_NUM" '.[] | select(.number==$n) | .head.sha')

            # Combined commit status (Vercel posts a commit status). Require at least one
            # status present AND overall state == success — so a not-yet-built PR (no statuses)
            # does NOT count as green.
            local STATUS_JSON STATE NSTAT
            STATUS_JSON=$(gh api "repos/$REPO/commits/$HEAD_SHA/status" 2>/dev/null)
            STATE=$(echo "$STATUS_JSON" | jq -r '.state')
            NSTAT=$(echo "$STATUS_JSON" | jq -r '.total_count')

            # Review gates merge: require the review stage's approval label AND no
            # open CHANGES_REQUESTED review AND no `danger` label. A fresh PR has
            # no approval label, so it does NOT merge before review runs (this was
            # the bug: a just-opened PR merged because "no changes-requested" was
            # mistaken for approval). The label — not a GitHub APPROVED review — is
            # the signal because the pipeline authors its own PRs and GitHub
            # forbids approving your own PR. The review stage adds `reviewed-ok`
            # only after /code-review comes back clean (see PROCESS-TASK.md).
            local LABELS APPROVED_LABEL DANGER
            LABELS=$(echo "$OPEN_PRS" | jq -r --argjson n "$PR_NUM" '.[] | select(.number==$n) | .labels[].name')
            APPROVED_LABEL=$(echo "$LABELS" | grep -cx "reviewed-ok")
            DANGER=$(echo "$LABELS"        | grep -cx "danger")

            # Any open CHANGES_REQUESTED review (latest per reviewer) still blocks.
            local CR
            CR=$(gh api "repos/$REPO/pulls/$PR_NUM/reviews?per_page=100" 2>/dev/null \
                | jq -r '[ .[] | select(.state=="APPROVED" or .state=="CHANGES_REQUESTED" or .state=="DISMISSED") ]
                         | group_by(.user.login) | map(max_by(.submitted_at) | .state)
                         | [ .[] | select(.=="CHANGES_REQUESTED") ] | length')

            # Mergeability (skip conflicts).
            local MERGEABLE
            MERGEABLE=$(gh api "repos/$REPO/pulls/$PR_NUM" 2>/dev/null | jq -r '.mergeable_state')

            if [ "$STATE" = "success" ] && [ "${NSTAT:-0}" -ge 1 ] && [ "${APPROVED_LABEL:-0}" -ge 1 ] && [ "${DANGER:-0}" = "0" ] && [ "${CR:-0}" = "0" ] && [ "$MERGEABLE" != "dirty" ]; then
                # Rebase-merge (NOT squash): a squash commit is authored by the
                # merging account (the ClaudeCodeRoiAgent bot, whose email
                # roikedem+claudecode@gmail.com is not on the Vercel/GitHub owner
                # account), which Vercel Hobby blocks ("commit author could not be
                # matched"). Rebase preserves each commit's real author — the
                # Solver authors as roikedem@gmail.com — so the commit landing on
                # dev has an author Vercel accepts and the preview deploys.
                if gh pr merge "$PR_NUM" --repo "$REPO" --rebase --delete-branch >/dev/null 2>&1; then
                    log "AUTO-MERGED $REPO PR #$PR_NUM into $BASE_BRANCH (rebase; status=success, reviewed-ok, no danger/changes-requested)"
                    ADDED=$((ADDED + 1))
                else
                    log "auto-merge FAILED for $REPO PR #$PR_NUM (state=$STATE n=$NSTAT reviewed_ok=$APPROVED_LABEL mergeable=$MERGEABLE)"
                fi
            else
                log "auto-merge skip $REPO PR #$PR_NUM: state=$STATE n=$NSTAT reviewed_ok=$APPROVED_LABEL danger=$DANGER changes_requested=$CR mergeable=$MERGEABLE"
            fi
        done <<< "$PR_NUMBERS"
    fi

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
