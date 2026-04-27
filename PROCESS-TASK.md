# How to process Jira Issue/comment or Github PR conversation/comment 

## Configuration

github and atlassian/jira Project-specific values are defined in `.jira-process.json` in the project directory.

Read that file at the start of each session to resolve `{placeholders}` below.

## Entry Point

When invoked from cron, a single task has been popped from the queue and its details are already available as environment variables:

| Variable | Content |
|---|---|
| `$TASK_TYPE` | `jira_issue`, `jira_comment`, `github_pr_comment`, `github_pr_review`, `github_pr_merged` |
| `$TASK_KEY` | Jira issue key (e.g. `KNS-68`) |
| `$TASK_SUMMARY` | Issue summary |
| `$TASK_COMMENT_ID` | Comment ID (for `jira_comment` / `github_pr_comment`) |
| `$TASK_COMMENT_BODY` | Comment text |
| `$TASK_COMMENT_AUTHOR` | Comment author |
| `$TASK_PR_NUMBER` | PR number (for GitHub tasks) |
| `$TASK_PR_TITLE` | PR title |
| `$TASK_BRANCH` | Branch name |
| `$TASK_REVIEW_STATE` | `CHANGES_REQUESTED` or `APPROVED` (for `github_pr_review`) |
| `$GH_TOKEN` | GitHub token for `gh` commands — already set, do not override |
| `$TASK_CONTEXT_FILE` | Task context file |
| `$TASK_CONTEXT_DIRECTORY` | Task context directory |

---


## Session Start: Read Dev Context First

Before doing anything else, read `$TASK_CONTEXT_FILE` if it exists.

- **`Status: done`** — skip entirely. Already fully handled.
- **`Status: waiting for PR review`** — no action needed here; the PR Review Loop (section E) handles merged PRs.
- **`Status: waiting for user`** — skip. A comment was already posted on Jira. Do **not** comment again until the issue has new activity (a reply, status change, or new comment since the "Blocked since" timestamp).
- **`Status: in progress — addressing PR feedback`** — resume this work first.
- **`Status: in progress`** — resume this work before picking up new issues.

Then route based on `$TASK_TYPE`:
- `jira_issue` — go to **step 0** (start of issue workflow)
- `jira_comment` — new comment on `$TASK_KEY`; read the issue and respond/resume work from the appropriate step
- `github_pr_comment` — new inline comment on PR `$TASK_PR_NUMBER`; go to **PR Review → step C**
- `github_pr_review` — review on PR `$TASK_PR_NUMBER`; go to **PR Review → step C**
- `github_pr_merged` — PR `$TASK_PR_NUMBER` was merged; go to **PR Review → step E**

## Action Logging

Throughout the session, append a one-line entry to `$TASK_CONTEXT_FILE` for every significant decision or action taken:

```
[<ISO 8601 timestamp>] <action or decision>
```

Examples:
```
[2026-04-27T10:05:00Z] Read issue: DNS link check after production migration
[2026-04-27T10:05:30Z] Transitioned Jira to In Progress
[2026-04-27T10:06:00Z] Created branch KNS-36-check-monday-links
[2026-04-27T10:20:00Z] Fixed: updated exportLinks() to use new domain
[2026-04-27T10:21:00Z] Wrote testplan to testplan.txt, commented on Jira
[2026-04-27T10:22:00Z] Created PR #42, transitioned Jira to Review
```

---

Follow these steps in order when working on a Jira issue.

---

## 0. Backup Database (if needed)

If the issue involves any of the following, **backup the database before starting**:

- Database schema changes (adding/removing/changing columns or tables)
- Adding or removing entity types, bundles, or fields
- Taxonomy or config changes that alter stored data

```bash
{backup_command}
```

---

## 1. Read the Issue

- Fetch the full issue details including description, comments, and any linked issues.
- Understand the acceptance criteria and scope before touching any code.

**Tool:** `mcp__atlassian__getJiraIssue` with `cloudId: {jira_cloud_id}`

---

## 2. Move to "In Progress"

**This step is required. Do not skip it.**

- Transition the issue status to **In Progress** before starting work.

**Tool:** `mcp__atlassian__getTransitionsForJiraIssue` to get the transition ID, then `mcp__atlassian__transitionJiraIssue`.

Log: `Transitioned Jira $TASK_KEY to In Progress`

---

## 3. Create a Git Branch

- Branch off `{default_branch}` of the relevant repo.
- Use the Jira issue key in the branch name:

```bash
git checkout -b "$TASK_KEY-short-description"
```

- For backend changes: branch in `{primary_repo}`.
- For frontend changes: branch in `{frontend_submodule}/` (the `{frontend_repo}` submodule).
- For changes spanning both: create matching branches in both repos.

**Take a "before" screenshot — required before touching any code:**

- Identify the URL(s) in the local site that show the problem.
- For each affected URL, take a screenshot of the relevant section using the helper script:

```bash
node ~/projects/dev-ai/scripts/screenshot.js "<url>" "<css-selector>" "$TASK_CONTEXT_DIRECTORY/before.png"
```

- Create `$TASK_CONTEXT_DIRECTORY/index.html` documenting the context:

```html
<!DOCTYPE html>
<html>
<head><meta charset="utf-8"><title>$TASK_KEY screenshots</title></head>
<body>
  <h1>$TASK_KEY: <issue title></h1>
  <h2>Before</h2>
  <p><strong>URL:</strong> <a href="<url>"><url></a></p>
  <p><strong>Taken:</strong> <ISO 8601 timestamp></p>
  <img src="before.png" alt="before">
  <h2>After</h2>
  <p><em>(to be filled in after the fix)</em></p>
</body>
</html>
```

**Create `$TASK_CONTEXT_FILE`:**

Initial content:
```
# $TASK_KEY: <issue title>

## Status: in progress

## What this is
<one-paragraph summary of the issue and the plan>

## What was done
(fill in as work progresses)

## Current step
Step 4 — solving
```

---

## 3b. If the Issue Cannot Be Solved

If you are blocked — missing context, requires a decision, or beyond current scope:

1. Post **one** comment on the Jira issue explaining what is blocking you and what is needed. @mention the user: `{jira_user_mention}`. Do not post this comment again in future sessions.

2. Update `$TASK_CONTEXT_FILE`:
   ```
   ## Status: waiting for user

   ## Blocked since
   <ISO 8601 timestamp>

   ## Why blocked
   <one paragraph — what is missing or what decision is needed>
   ```

3. Return to `{default_branch}` and pick up a different issue.

When checking this issue in future sessions — only act if there is new activity (a reply or status change since the "Blocked since" timestamp). Otherwise skip it entirely.

---

## 4. Solve the Issue

- Make the minimal change that satisfies the issue. Don't expand scope.
- Follow conventions already established in the relevant module/component.
- Run project-specific test commands from `.jira-process.json` after changes.

---

## 5. Test

**Both of the following are required before proceeding to step 6:**

1. Write the testplan to `$TASK_CONTEXT_DIRECTORY/testplan.txt`.
2. Post the testplan as a comment on the Jira issue (`mcp__atlassian__addCommentToJiraIssue`).

Then run tests:
- Run tests from the testplan.
- Run all relevant test commands defined in `.jira-process.json` (`test_commands.backend`, `test_commands.frontend`).
- Exercise the affected path manually and verify in the browser.
- Update testplan results on the Jira issue comment.
- Confirm the original symptom described in the Jira issue is resolved.

**Take an "after" screenshot — required before committing:**

```bash
node ~/projects/dev-ai/scripts/screenshot.js "<url>" "<css-selector>" "$TASK_CONTEXT_DIRECTORY/after.png"
```

Update `$TASK_CONTEXT_DIRECTORY/index.html` — fill in the After section:

```html
  <h2>After</h2>
  <p><strong>URL:</strong> <a href="<url>"><url></a></p>
  <p><strong>Taken:</strong> <ISO 8601 timestamp></p>
  <img src="after.png" alt="after">
```

---

## 6. Commit

- Include the Jira issue key at the start of the commit message:

```bash
git commit -m "$TASK_KEY: brief description of what and why"
```

- Stage only relevant files — avoid accidentally committing `.env`, config exports, or unrelated changes.

---

## 7. Create a Pull Request

- Push the feature branch only — do NOT push to `{default_branch}`. The user reviews and merges the PR:

```bash
git push -u origin <branch-name>
gh pr create --title "$TASK_KEY: brief description" --body "..."
```

- PR body should reference the Jira issue key and summarize what changed and why.
- **Never post a GitHub compare link as a substitute for a PR.** If `gh pr create` fails, verify `$GH_TOKEN` is set (`echo $GH_TOKEN`) and retry. Only post to Jira once a real PR URL exists.
- Before creating the PR, confirm you are authenticated as the agent: `gh api user --jq .login` must return `ClaudeCodeRoiAgent`. If it returns another user, stop and fix the auth before proceeding.
- For submodule (`{frontend_submodule}/`) changes, also update the submodule pointer in `{primary_repo}` and open a coordinated PR there if needed.

**Transition the Jira issue to "Review" — required before moving on:**

**Tool:** `mcp__atlassian__getTransitionsForJiraIssue` to find the "Review" transition ID, then `mcp__atlassian__transitionJiraIssue`.

Log: `Transitioned Jira $TASK_KEY to Review, PR: <PR URL>`

**Update `$TASK_CONTEXT_FILE`:**

```
## Status: waiting for PR review

## What was done
<summary of changes made>

## Waiting since
<ISO 8601 timestamp, e.g. 2026-04-18T14:32:00Z>

## PR
<PR URL>
```

---

## 8. Comment on the Jira Issue

- Post a comment on the Jira issue with:
  - A link to the PR.
  - A brief summary of what was done.
  - Any follow-up notes or caveats.

**Tool:** `mcp__atlassian__addCommentToJiraIssue` with `cloudId: {jira_cloud_id}`

---

## 9. Return to Default Branch

```bash
git checkout {default_branch} && git pull
```

---

## 10. Restore Database (if needed)

If a backup was taken in step 0, restore it when returning to the default branch so the database schema matches:

```bash
{restore_command}
```

---

## PR Review

### A. Fetch the PR

```bash
gh pr view "$TASK_PR_NUMBER" --repo {github_repo} --json number,title,headRefName,url,state,mergedAt
```

### B. Check PR for Unresolved Comments

For PR `$TASK_PR_NUMBER`, fetch all review comments and issue comments left by `{github_user}`:

```bash
gh pr view "$TASK_PR_NUMBER" --repo {github_repo} --json reviews,comments,headRefName
gh api repos/{github_repo}/pulls/"$TASK_PR_NUMBER"/comments
gh api repos/{github_repo}/issues/"$TASK_PR_NUMBER"/comments
```

A comment needs action if:
- It was posted by `{github_user}`, AND
- Claude has not yet replied to it (no subsequent commit or reply comment referencing it), AND
- It is not marked as resolved (for review comments: `position` is not null and no reply exists)

If no actionable comments exist — nothing to do for this task.

### C. Address Each Comment

1. **Immediately update `$TASK_CONTEXT_FILE`** — before touching any code. This prevents a concurrent cron instance from picking up the same comment. Record the comment ID so it is never re-processed:

```
## Status: in progress — addressing PR feedback

## Comments being addressed
- Comment ID <id>: "<first ~60 chars of comment text>"

## Addressing since
<ISO 8601 timestamp>
```

   When reading the context file at session start, skip any comment ID already listed here.

2. **Check out the branch:**
   ```bash
   git fetch origin
   git checkout <headRefName>
   ```

3. **Read the full comment in context** — understand what change is being requested before touching code.

4. **Make the fix** — minimal change that satisfies the comment. Don't expand scope.

5. **Test** — update `$TASK_CONTEXT_DIRECTORY/testplan.txt` if needed and comment on Jira if the testplan changed. Run it.

6. **Commit**, referencing the PR:
   ```bash
   git commit -m "$TASK_KEY: address PR feedback — brief description"
   ```

7. **Push:**
   ```bash
   git push
   ```

8. **Reply to the comment** to confirm it was addressed:
   ```bash
   gh api repos/{github_repo}/issues/"$TASK_PR_NUMBER"/comments \
     --method POST \
     --field body="Addressed in <commit sha> — brief explanation of what changed."
   ```

9. **Transition the Jira issue back to "Review":**

   **Tool:** `mcp__atlassian__getTransitionsForJiraIssue` then `mcp__atlassian__transitionJiraIssue`.

10. **Update `$TASK_CONTEXT_FILE`:**

```
## Status: waiting for PR review

## What was done
<append what was fixed in response to the comment>

## Waiting since
<ISO 8601 timestamp>
```

### D. Return to Default Branch

```bash
git checkout {default_branch} && git pull
```

---

### E. Merged PR → Move Jira to Done

1. **Transition Jira to Done:**

   **Tool:** `mcp__atlassian__getTransitionsForJiraIssue` to find the "Done" transition ID, then `mcp__atlassian__transitionJiraIssue`.

2. **Post before/after screenshots as a Jira comment:**

   - Upload both images as attachments to the issue:
     ```
     POST /rest/api/3/issue/$TASK_KEY/attachments
     ```
     Use `mcp__atlassian__fetch` with `multipart/form-data` for each file (`$TASK_CONTEXT_DIRECTORY/before.png`, `$TASK_CONTEXT_DIRECTORY/after.png`).

   - Post a comment referencing them:

     **Tool:** `mcp__atlassian__addCommentToJiraIssue` with body:
     ```
     *Before / After*

     URL: <url from index.html>

     !before.png|thumbnail!  →  !after.png|thumbnail!
     ```

3. **Archive the context directory** — move it so it never surfaces in future sessions:
   ```bash
   mkdir -p ~/dev-context/archive
   mv "$TASK_CONTEXT_DIRECTORY" ~/dev-context/archive/
   ```

