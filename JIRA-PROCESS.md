# Jira Issue Resolution Process

> **Configuration:** Project-specific values are defined in `.jira-process.json` in the project directory.
> Read that file at the start of each session to resolve `{placeholders}` below.

## Entry Point

When invoked from cron or manually without context, start here:

1. Read `dev-context/` for in-progress work
2. Run the PR Review Loop
3. Check Jira for new assigned issues

---

## Cron Setup (one-time, per machine)

Run from `~/projects/dev-ai`:

```bash
# 1. In the target project directory — create required dirs and gitignore entries
cd /path/to/project   # e.g. ~/projects/pandit
mkdir -p logs
grep -qxF 'logs/claude-jira.log' .gitignore || echo 'logs/claude-jira.log' >> .gitignore
grep -qxF '.claude-jira.lock'    .gitignore || echo '.claude-jira.lock'    >> .gitignore

# 2. Make the cron script executable (run from dev-ai)
cd ~/projects/dev-ai
chmod +x scripts/claude-jira-cron.sh

# 3. Print the crontab line to add (crontab -e)
echo "*/5 * * * * $(pwd)/scripts/claude-jira-cron.sh /path/to/project"
# e.g.: */5 * * * * /home/roi/projects/dev-ai/scripts/claude-jira-cron.sh /home/roi/projects/pandit
```

The script (`scripts/claude-jira-cron.sh`) handles locking, timestamped logging, and locating `claude` via PATH.

Ensure `gh` is authenticated as the Claude agent account:

```bash
gh auth switch --user ClaudeCodeRoiAgent
```

For before/after screenshots, install Puppeteer once per machine:

```bash
npm install puppeteer
```

---

## Session Start: Read Dev Context First

Before doing anything else, read all files in `dev-context/` (excluding `dev-context/archive/`). Each file is named after a branch (`{jira_project_key}-XX-short-description.md`) and describes the current state of that work.

- **`Status: done`** — skip entirely. Already fully handled.
- **`Status: waiting for PR review`** — no action needed here; the PR Review Loop (section E) handles merged PRs.
- **`Status: waiting for user`** — skip. A comment was already posted on Jira. Do **not** comment again until the issue has new activity (a reply, status change, or new comment since the "Blocked since" timestamp).
- **`Status: in progress — addressing PR feedback`** — resume this work first.
- **`Status: in progress`** — resume this work before picking up new issues.

Multiple branches can be in-flight at the same time. **Always verify which branch you are on before editing any file.** Never commit work from one issue onto another branch.

---

Follow these steps in order when working on a Jira issue.

---

## Finding Issues to Solve

Query Jira for open issues assigned to you:

**JQL:** `project={jira_project_key} AND assignee="{jira_assignee}" ORDER BY created DESC`

**Tool:** `mcp__atlassian__searchJiraIssuesUsingJql`
```
jql: "project={jira_project_key} AND assignee=\"{jira_assignee}\" ORDER BY created DESC"
fields: "summary,status,issuetype,priority"
```

Work through them in priority order (High → Medium → Low). Pick one, then follow the steps below.

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

- Transition the issue status to **In Progress** before starting work.

**Tool:** `mcp__atlassian__getTransitionsForJiraIssue` to get the transition ID, then `mcp__atlassian__transitionJiraIssue`.

---

## 3. Create a Git Branch

- Branch off `{default_branch}` of the relevant repo.
- Use the Jira issue key in the branch name:

```bash
git checkout -b {jira_project_key}-XX-short-description
```

- For backend changes: branch in `{primary_repo}`.
- For frontend changes: branch in `{frontend_submodule}/` (the `{frontend_repo}` submodule).
- For changes spanning both: create matching branches in both repos.

**Take a "before" screenshot:**

- Identify the URL(s) in the local site that show the problem.
- For each affected URL, take a screenshot of the relevant section using the helper script:

```bash
node scripts/screenshot.js "<url>" "<css-selector>" docs/screenshots/{jira_project_key}-XX/before.png
```

- Create `docs/screenshots/{jira_project_key}-XX/index.html` documenting the context:

```html
<!DOCTYPE html>
<html>
<head><meta charset="utf-8"><title>{jira_project_key}-XX screenshots</title></head>
<body>
  <h1>{jira_project_key}-XX: <issue title></h1>
  <h2>Before</h2>
  <p><strong>URL:</strong> <a href="<url>"><url></a></p>
  <p><strong>Taken:</strong> <ISO 8601 timestamp></p>
  <img src="before.png" alt="before">
  <h2>After</h2>
  <p><em>(to be filled in after the fix)</em></p>
</body>
</html>
```

**Create the dev-context file:**

```
dev-context/{jira_project_key}-XX-short-description.md
```

Initial content:
```
# {jira_project_key}-XX: <issue title>

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

2. Update the dev-context file:
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

- Write testplan — update it as a comment on the Jira issue.
- Run tests from the testplan.
- Run all relevant test commands defined in `.jira-process.json` (`test_commands.backend`, `test_commands.frontend`).
- Exercise the affected path manually and verify in the browser.
- Update testplan results on the Jira issue comment.
- Confirm the original symptom described in the Jira issue is resolved.

**Take an "after" screenshot:**

```bash
node scripts/screenshot.js "<url>" "<css-selector>" docs/screenshots/{jira_project_key}-XX/after.png
```

Update `docs/screenshots/{jira_project_key}-XX/index.html` — fill in the After section:

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
git commit -m "{jira_project_key}-XX: brief description of what and why"
```

- Stage only relevant files — avoid accidentally committing `.env`, config exports, or unrelated changes.

---

## 7. Create a Pull Request

- Push the feature branch only — do NOT push to `{default_branch}`. The user reviews and merges the PR:

```bash
git push -u origin {jira_project_key}-XX-short-description
gh pr create --title "{jira_project_key}-XX: brief description" --body "..."
```

- PR body should reference the Jira issue key and summarize what changed and why.
- For submodule (`{frontend_submodule}/`) changes, also update the submodule pointer in `{primary_repo}` and open a coordinated PR there if needed.

**Update the dev-context file:**

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

## 9. Return to Default Branch and Pick Up Next Issue

```bash
git checkout {default_branch}
```

Do not wait for the PR to be reviewed — return to the **Finding Issues to Solve** step and pick up the next assigned issue immediately.

---

## 10. Restore Database (if needed)

If a backup was taken in step 0, restore it when returning to the default branch so the database schema matches:

```bash
{restore_command}
```

---

## 11. Open the PR in Chrome

Running in WSL2 — Chrome is on Windows, so use PowerShell:

```bash
powershell.exe -c "Start-Process '<PR URL>'"
```

---

---

## PR Review Loop

Run this at the start of each session (after reading dev-context) to handle feedback on open PRs and detect merged ones.

### A. List Open PRs

```bash
gh pr list --repo {github_repo} --state open --json number,title,headRefName,url
```

### B. Check Each PR for Unresolved Comments

For each open PR, fetch all review comments and issue comments left by `{github_user}`:

```bash
gh pr view <number> --repo {github_repo} --json reviews,comments,headRefName
gh api repos/{github_repo}/pulls/<number>/comments
gh api repos/{github_repo}/issues/<number>/comments
```

A comment needs action if:
- It was posted by `{github_user}`, AND
- Claude has not yet replied to it (no subsequent commit or reply comment referencing it), AND
- It is not marked as resolved (for review comments: `position` is not null and no reply exists)

If no actionable comments exist on any PR — move on to section E (merged PR check), then check Jira for new issues.

### C. Address Each Comment

For each PR with actionable comments:

1. **Immediately update the dev-context file** — before touching any code. This prevents a concurrent cron instance from picking up the same comment. Record the comment ID so it is never re-processed:

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

5. **Test** — run relevant test commands from `.jira-process.json`.

6. **Commit**, referencing the PR:
   ```bash
   git commit -m "{jira_project_key}-XX: address PR feedback — brief description"
   ```

7. **Push:**
   ```bash
   git push
   ```

8. **Reply to the comment** to confirm it was addressed:
   ```bash
   gh api repos/{github_repo}/issues/<number>/comments \
     --method POST \
     --field body="Addressed in <commit sha> — brief explanation of what changed."
   ```

9. **Update the dev-context file:**

```
## Status: waiting for PR review

## What was done
<append what was fixed in response to the comment>

## Waiting since
<ISO 8601 timestamp>
```

### D. Return to Default Branch

```bash
git checkout {default_branch}
```

---

### E. Check for Merged PRs → Move Jira to Done

For each dev-context file with `Status: waiting for PR review`:

1. **Check if the PR is merged:**
   ```bash
   gh pr view <number> --repo {github_repo} --json state,mergedAt
   ```

2. **If merged** — transition the Jira issue to **Done**:

   **Tool:** `mcp__atlassian__getTransitionsForJiraIssue` to find the "Done" transition ID, then `mcp__atlassian__transitionJiraIssue`.

3. **Post before/after screenshots as a Jira comment:**

   - Upload both images as attachments to the issue:
     ```
     POST /rest/api/3/issue/{issueKey}/attachments
     ```
     Use `mcp__atlassian__fetch` with `multipart/form-data` for each file (`before.png`, `after.png`).

   - Post a comment referencing them:

     **Tool:** `mcp__atlassian__addCommentToJiraIssue` with body:
     ```
     *Before / After*

     URL: <url from index.html>

     !before.png|thumbnail!  →  !after.png|thumbnail!
     ```

4. **Archive the dev-context file** — move it so it never surfaces in future sessions:
   ```bash
   mkdir -p dev-context/archive
   git mv dev-context/{jira_project_key}-XX-short-description.md dev-context/archive/
   git commit -m "{jira_project_key}-XX: archive dev-context — PR merged and issue done"
   git push
   ```

5. If still open — leave as-is and continue.

---

## Quick Reference

| Step | Action | Tool / Command |
|------|--------|----------------|
| 0 | Backup DB (if schema/entity changes) | `{backup_command}` |
| 1 | Read issue | `mcp__atlassian__getJiraIssue` |
| 2 | Move to In Progress | `mcp__atlassian__transitionJiraIssue` |
| 3 | Create branch + before screenshot | `git checkout -b {jira_project_key}-XX-...` |
| 3b | Blocked → comment once + mark waiting | `mcp__atlassian__addCommentToJiraIssue` |
| 4 | Solve | edit code |
| 5 | Test + after screenshot | `ddev drush cr` / `npm run build` / browser |
| 6 | Commit | `git commit -m "{jira_project_key}-XX: ..."` |
| 7 | PR | `gh pr create` |
| 8 | Comment on issue | `mcp__atlassian__addCommentToJiraIssue` |
| 9 | Return to default branch, pick up next issue | `git checkout {default_branch}` |
| 10 | Restore DB (if schema changed) | `{restore_command}` |
| 11 | Open PR in Chrome | `powershell.exe -c "Start-Process '<PR URL>'"` |
| PR loop E | PR merged → Done + screenshots + archive dev-context | `mcp__atlassian__transitionJiraIssue` |
