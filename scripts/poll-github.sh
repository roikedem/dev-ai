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

# Jira creds (optional) — used to read the "auto-merge" label on a PR's issue.
# If absent, the per-issue auto-merge path is simply skipped.
JIRA_API_TOKEN_FILE="$HOME/.config/atlassian-api-token"
JIRA_EMAIL="roikedem+claudecode@gmail.com"
JIRA_API_TOKEN=""
[ -f "$JIRA_API_TOKEN_FILE" ] && JIRA_API_TOKEN=$(tr -d '\r\n' < "$JIRA_API_TOKEN_FILE")

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

    # --- Auto-merge integration-branch PRs ---
    # A PR into the repo's base_branch (e.g. dev) is auto-merged when it's
    # review-approved and unblocked. Two ways a PR becomes auto-merge-eligible:
    #   (a) repo-level: .repos[].auto_merge_when_green == true  (CI-gated — the
    #       'Vercel' commit status must be green; used by deploying repos like
    #       knesset-front).
    #   (b) per-issue: the linked Jira issue carries the "auto-merge" label
    #       (case-insensitive). This works even in repos that normally don't
    #       auto-merge (e.g. the Drupal knesset-data repo, which has no CI) — so
    #       CI-green is NOT required on this path, only review approval.
    # Either way the merge target must be the repo's base_branch (always dev for
    # these), and review still gates it. Promotion dev->master is never touched.
    local REPO_AUTO_MERGE BASE_BRANCH
    REPO_AUTO_MERGE=$(jq -r --arg r "$REPO" '.repos[] | select(.github==$r) | .auto_merge_when_green // false' "$CONFIG")
    BASE_BRANCH=$(jq -r --arg r "$REPO" '.repos[] | select(.github==$r) | .base_branch // empty' "$CONFIG")
    if [ -n "$BASE_BRANCH" ]; then
        while IFS= read -r PR_NUM; do
            [ -z "$PR_NUM" ] && continue
            local PR_BASE HEAD_SHA PR_BRANCH2
            PR_BASE=$(echo "$OPEN_PRS" | jq -r --argjson n "$PR_NUM" '.[] | select(.number==$n) | .base.ref')
            [ "$PR_BASE" = "$BASE_BRANCH" ] || continue
            HEAD_SHA=$(echo "$OPEN_PRS" | jq -r --argjson n "$PR_NUM" '.[] | select(.number==$n) | .head.sha')
            PR_BRANCH2=$(echo "$OPEN_PRS" | jq -r --argjson n "$PR_NUM" '.[] | select(.number==$n) | .head.ref')

            # Per-issue "auto-merge" Jira label? Derive the Jira key from the
            # branch name (e.g. KNS-80-foo -> KNS-80) and check its labels.
            local ISSUE_AUTO_MERGE JIRA_KEY
            ISSUE_AUTO_MERGE=false
            JIRA_KEY=$(echo "$PR_BRANCH2" | grep -oiE '^[a-z]+-[0-9]+' | tr '[:lower:]' '[:upper:]')
            if [ -n "$JIRA_KEY" ] && [ -f "$JIRA_API_TOKEN_FILE" ]; then
                local _LBLS
                _LBLS=$(curl -sf -u "$JIRA_EMAIL:$JIRA_API_TOKEN" -H "Accept: application/json" \
                    "https://intotodev.atlassian.net/rest/api/3/issue/$JIRA_KEY?fields=labels" 2>/dev/null \
                    | jq -r '.fields.labels[]? | ascii_downcase')
                echo "$_LBLS" | grep -qx "auto-merge" && ISSUE_AUTO_MERGE=true
            fi

            # Skip unless this PR is eligible by repo flag OR issue label.
            if [ "$REPO_AUTO_MERGE" != "true" ] && [ "$ISSUE_AUTO_MERGE" != "true" ]; then
                continue
            fi

            # Combined commit status (Vercel posts one). Require at least one
            # status present AND overall state == success. Only enforced on the
            # repo-flag (CI) path; the issue-label path does not require CI.
            local STATUS_JSON STATE NSTAT CI_OK
            STATUS_JSON=$(gh api "repos/$REPO/commits/$HEAD_SHA/status" 2>/dev/null)
            STATE=$(echo "$STATUS_JSON" | jq -r '.state')
            NSTAT=$(echo "$STATUS_JSON" | jq -r '.total_count')
            if [ "$REPO_AUTO_MERGE" = "true" ]; then
                if [ "$STATE" = "success" ] && [ "${NSTAT:-0}" -ge 1 ]; then CI_OK=1; else CI_OK=0; fi
            else
                CI_OK=1  # issue-label path: no CI requirement
            fi

            # Review gates merge: require the review stage's approval label AND no
            # open CHANGES_REQUESTED review AND no `danger` label. A fresh PR has
            # no approval label, so it does NOT merge before review runs. The label
            # — not a GitHub APPROVED review — is the signal because the pipeline
            # authors its own PRs and GitHub forbids approving your own PR. The
            # review stage adds `reviewed-ok` only after /code-review is clean.
            local LABELS APPROVED_LABEL DANGER PENDING_SIBLING
            LABELS=$(echo "$OPEN_PRS" | jq -r --argjson n "$PR_NUM" '.[] | select(.number==$n) | .labels[].name')
            APPROVED_LABEL=$(echo "$LABELS" | grep -cx "reviewed-ok")
            DANGER=$(echo "$LABELS"        | grep -cx "danger")

            # Sibling release: the review stage reviewed this front PR clean but
            # withheld `reviewed-ok` because a paired manual-review PR (same Jira
            # key, e.g. the Drupal backend) was still OPEN — marking it
            # `reviewed-pending-sibling` instead. Once that sibling PR is no longer
            # open (Roi merged it), promote pending→approved automatically so the
            # front merges without a human re-running the approve step.
            PENDING_SIBLING=$(echo "$LABELS" | grep -cx "reviewed-pending-sibling")
            if [ "${APPROVED_LABEL:-0}" -lt 1 ] && [ "${PENDING_SIBLING:-0}" -ge 1 ] && [ -n "$JIRA_KEY" ]; then
                local SIB_OPEN=0
                for sib_repo in $(jq -r '.repos[].github' "$CONFIG"); do
                    [ "$sib_repo" = "$REPO" ] && continue
                    local n_open
                    n_open=$(gh api "repos/$sib_repo/pulls?state=open&per_page=50" 2>/dev/null \
                        | jq --arg k "$JIRA_KEY" '[ .[] | select((.head.ref // "") | ascii_upcase | startswith($k + "-") or . == $k) ] | length' 2>/dev/null)
                    SIB_OPEN=$(( SIB_OPEN + ${n_open:-0} ))
                done
                if [ "$SIB_OPEN" -eq 0 ]; then
                    gh pr edit "$PR_NUM" --repo "$REPO" --add-label "reviewed-ok" --remove-label "reviewed-pending-sibling" >/dev/null 2>&1
                    APPROVED_LABEL=1
                    log "sibling released $REPO PR #$PR_NUM ($JIRA_KEY): no open sibling PR → promoted reviewed-pending-sibling to reviewed-ok"
                fi
            fi

            # Any open CHANGES_REQUESTED review (latest per reviewer) still blocks.
            local CR
            CR=$(gh api "repos/$REPO/pulls/$PR_NUM/reviews?per_page=100" 2>/dev/null \
                | jq -r '[ .[] | select(.state=="APPROVED" or .state=="CHANGES_REQUESTED" or .state=="DISMISSED") ]
                         | group_by(.user.login) | map(max_by(.submitted_at) | .state)
                         | [ .[] | select(.=="CHANGES_REQUESTED") ] | length')

            # Mergeability (skip conflicts).
            local MERGEABLE
            MERGEABLE=$(gh api "repos/$REPO/pulls/$PR_NUM" 2>/dev/null | jq -r '.mergeable_state')

            if [ "${CI_OK:-0}" = "1" ] && [ "${APPROVED_LABEL:-0}" -ge 1 ] && [ "${DANGER:-0}" = "0" ] && [ "${CR:-0}" = "0" ] && [ "$MERGEABLE" != "dirty" ]; then
                # Rebase-merge (NOT squash): a squash commit is authored by the
                # merging account (the ClaudeCodeRoiAgent bot, whose email
                # roikedem+claudecode@gmail.com is not on the Vercel/GitHub owner
                # account), which Vercel Hobby blocks ("commit author could not be
                # matched"). Rebase preserves each commit's real author — the
                # Solver authors as roikedem@gmail.com — so the commit landing on
                # dev has an author Vercel accepts and the preview deploys.
                local TRIGGER; [ "$ISSUE_AUTO_MERGE" = "true" ] && TRIGGER="jira:auto-merge" || TRIGGER="repo:auto_merge_when_green"
                if gh pr merge "$PR_NUM" --repo "$REPO" --rebase --delete-branch >/dev/null 2>&1; then
                    log "AUTO-MERGED $REPO PR #$PR_NUM into $BASE_BRANCH (rebase; via $TRIGGER; ci_ok=$CI_OK reviewed-ok, no danger/changes-requested)"
                    ADDED=$((ADDED + 1))
                else
                    log "auto-merge FAILED for $REPO PR #$PR_NUM (via $TRIGGER; state=$STATE n=$NSTAT reviewed_ok=$APPROVED_LABEL mergeable=$MERGEABLE)"
                fi
            else
                log "auto-merge skip $REPO PR #$PR_NUM: ci_ok=$CI_OK state=$STATE n=$NSTAT reviewed_ok=$APPROVED_LABEL danger=$DANGER changes_requested=$CR mergeable=$MERGEABLE issue_label=$ISSUE_AUTO_MERGE"
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
