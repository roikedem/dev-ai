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


## Session Setup

Before anything else, run:

```bash
source ~/projects/dev-ai/scripts/session-setup.sh
```

Then verify: `gh api user --jq .login` must return `ClaudeCodeRoiAgent`. If it returns another user, stop — do not create any PRs or comments until this is resolved.

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

- Branch off each repo's **`base_branch`** (read from that repo's entry in `repos[]` in `.jira-process.json`; falls back to `{default_branch}` if the repo has no `base_branch`). Different repos in the same project may have different base branches — e.g. `knesset-front` branches off `dev`, `knesset-data` off `master`. Always `git fetch` and branch off the up-to-date remote base (`origin/<base_branch>`).
- Use the Jira issue key in the branch name:

```bash
git fetch origin
git checkout -b "$TASK_KEY-short-description" "origin/<base_branch>"
```

- Create a branch in every repo that needs changes (read `repos` from `.jira-process.json`).
- Use the same branch name across all repos for traceability.

### Local environment + browser (REQUIRED for any UI/behaviour task)

Tests run against the **real local app**, exercised through a **real browser** that YOU (this session) drive via the **`playwright` MCP tools** (navigate, click, type, snapshot/read the DOM, screenshot). The browser runs headless on this host. Do NOT fake tests, and do NOT screenshot the login page as "the feature."

**1. Start the environment** (only what the task touches; this stage is project-agnostic — use whatever `.jira-process.json` declares for THIS project):
- **Drupal backend** (if the project has a ddev config / `local_urls.backend`): `cd {project_dir} && ddev start`. Backend URL = `local_urls.backend`.
- **Next.js front** (only if the project has a front and `local_urls.frontend`): `cd {project_dir}/front && npm install && (npm run dev &)` — serves `local_urls.frontend`. Wait until it responds before testing. (Drupal-only projects like pandit have no front — skip this.)
- If neither URL is declared, there's no live UI to browser-test; fall back to `test_commands` only.

**2. Ensure test users exist (you create them — like any real user, LOCAL ONLY).** Most features need login, and different features need different roles.
- **Drupal admin** (to control/inspect data): `ddev drush user:create tester_admin --mail="tester_admin@roikedem.com" --password="<pick>"` then `ddev drush user:role:add administrator tester_admin`.
- **Feature test users** (as many as the feature needs — e.g. an account manager + a plain member): create via the app's normal flow or `ddev drush user:create <name> --mail="<name>@roikedem.com" --password="<pick>"`, then grant the role the feature requires (`drush user:role:add <role> <name>`), and mark the email verified if the app gates on it (set `field_email_verified`/status as a normal user would be). Use **@roikedem.com** addresses.
- Record the users + passwords you used in `$TASK_CONTEXT_DIRECTORY/test-users.txt` so later sessions reuse them. Reuse existing ones if already present; reset a password with `ddev drush user:password <name> "<new>"`.
- **Email-driven flows (password reset, email verification, notifications):** give the test user a **`tester*@roikedem.com`** address (e.g. `tester-$TASK_KEY-mgr@roikedem.com`). App mail to any `tester*@roikedem.com` is captured and lands as JSON in `~/projects/team-emails/inbox/tester/` (via SES→Lambda→SQS→poller, usually within ~2 min). To test a reset/verification/notification: trigger it in the app, then read the newest file in `~/projects/team-emails/inbox/tester/` whose `to` matches your test address, extract the link/code from `body_text`, and continue in the browser. (Requires the SES receipt rule + Lambda to be deployed for the domain.)

**3. Log in through the browser.** Using the `playwright` MCP: navigate to the login page (`{local_urls.frontend}/login` for the front; `{local_urls.backend}/user/login` for Drupal admin), fill email+password of the appropriate test user, submit, and confirm you're authenticated (you land on the dashboard, not back on /login). Pick the user whose role matches what the feature requires.

**Take a "before" capture — required before touching any code:**

- Identify the URL(s) and the exact on-screen element that shows the problem.
- Log in (step 3), navigate to the affected screen, and screenshot **the relevant element/section** (not the whole login page) via the playwright MCP screenshot tool, saving to `$TASK_CONTEXT_DIRECTORY/before.png`. Also note in the testplan what the screen currently shows (the actual symptom).

- Create `$TASK_CONTEXT_DIRECTORY/index.html` documenting the context:

```html
<!DOCTYPE html>
<html>
<head><meta charset="utf-8"><title>$TASK_KEY test report</title></head>
<body>
  <h1>$TASK_KEY: <issue title></h1>
  <h2>Before</h2>
  <p><strong>URL:</strong> <a href="<url>"><url></a></p>
  <p><strong>Taken:</strong> <ISO 8601 timestamp></p>
  <p><strong>Observed symptom:</strong> <what the screen wrongly shows></p>
  <img src="before.png" alt="before" style="max-width:100%;border:1px solid #ccc">
  <h2>During (test steps)</h2>
  <p><em>(filled in as you run the testplan — one entry per significant step)</em></p>
  <h2>After</h2>
  <p><em>(to be filled in after the fix)</em></p>
</body>
</html>
```

This `index.html` is the **test report**: as you execute the testplan, capture a screenshot at each *significant* step (not only before/after) — e.g. the dialog you opened, the state after a click, the value that changed, any error — save them as `step-1.png`, `step-2.png`, … in `$TASK_CONTEXT_DIRECTORY`, and add a "During" entry per step with the step description, what you expected, what you observed, and the image. The finished report should let a reader follow the whole test visually: before → each meaningful interaction → after.

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

3. Return to `{default_branch}` and stop. This session handles one task only.

When checking this issue in future sessions — only act if there is new activity (a reply or status change since the "Blocked since" timestamp). Otherwise skip it entirely.

---

## 4. Solve the Issue

- Make the minimal change that satisfies the issue. Don't expand scope.
- Follow conventions already established in the relevant module/component.
- Run project-specific test commands from `.jira-process.json` after changes.

---

## 5. Test

**The test plan is for the TESTER (you, this session) to execute in the browser — not a checklist handed to Roi.** Write it as concrete steps an agent performs: which user/role to log in as, which URL, what to click/type, and the expected on-screen result for each step.

1. Write the testplan to `$TASK_CONTEXT_DIRECTORY/testplan.txt` as numbered executable steps, e.g.:
   `1. Log in as tester_manager@roikedem.com. 2. Open /dashboard/assignments. 3. Click "Add member". 4. Expect: dialog shows email+name+permissions fields. 5. Submit → expect the new member appears in the list.`
2. Post the testplan as a comment on the Jira issue (`mcp__atlassian__addCommentToJiraIssue`).

Then ACTUALLY run it through the browser (playwright MCP):
- Start the env + log in as the right-role test user (see "Local environment + browser" above).
- Execute each testplan step in the real browser: navigate, click, type, then **read the page (DOM snapshot / visible text) and assert the expected result actually happened** — don't assume; verify on screen.
- Also run the repo's `test_commands` (`.jira-process.json` → `test_commands.backend`/`frontend`, e.g. build + lint) and confirm they pass.
- Confirm the **original symptom** from the Jira issue is gone, by observing the fixed screen.
- Record pass/fail per step (with what you saw) in the testplan and update the Jira comment. If any step fails, fix and re-run — do not proceed with a failing testplan.

**Take an "after" screenshot — required before committing:**

- Via the playwright MCP, log in, navigate to the **same screen/element** as the before-shot, and screenshot the fixed element to `$TASK_CONTEXT_DIRECTORY/after.png`. It must show the actual tested feature (same framing as before.png), never the login page.

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

- Push the feature branch only — never push directly to a repo's `base_branch`. Target the PR at that repo's **`base_branch`** (from `repos[]` in `.jira-process.json`; fall back to `{default_branch}`):

```bash
git push -u origin <branch-name>
gh pr create --base <base_branch> --title "$TASK_KEY: brief description" --body "..."
```

- **Who merges depends on the repo's base branch:**
  - **Integration branch with `auto_merge_when_green: true`** (e.g. `knesset-front` → `dev`): the pipeline owns the merge, **but only after review**. The PR targets `dev`, which never deploys to production, so merging it is safe. After opening the PR, run the review-and-approve step (PR Review → step F): the poller merges it once **Vercel is green**, the **`reviewed-ok`** label is present, and nothing is blocking. Do not wait/block in this session; the merge happens in a later poll cycle.
  - **Production/default branch** (e.g. `knesset-data` → `master`): do **not** merge. Roi reviews and merges these himself — they deploy to production.
  - **Promotion `dev` → `master`** is always a separate, Roi-controlled PR. The pipeline never opens or auto-merges a PR into a production branch.
- PR body should reference the Jira issue key and summarize what changed and why.
- **Never post a GitHub compare link as a substitute for a PR.** If `gh pr create` fails, verify `$GH_TOKEN` is set (`echo $GH_TOKEN`) and retry. Only post to Jira once a real PR URL exists.
- Before creating the PR, confirm you are authenticated as the agent: `gh api user --jq .login` must return `ClaudeCodeRoiAgent`. If it returns another user, stop and fix the auth before proceeding.
- Open one PR per repo that has commits. Repos sharing a folder tree (e.g. `knesset-front` lives in `knesset-data/front/`) are **independent git repos, not submodules** — commit and PR each in its own repo against its own `base_branch`; never add/update a submodule pointer.

**Link the PR to the Jira issue** so it appears under the Development panel:

**Tool:** `mcp__atlassian__createIssueLink` — or use `mcp__atlassian__fetch` to POST a remote link:
```
POST /rest/api/3/issue/$TASK_KEY/remotelink
{
  "object": {
    "url": "<PR URL>",
    "title": "PR: <PR title>",
    "icon": { "url16x16": "https://github.com/favicon.ico", "title": "GitHub" }
  }
}
```

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
gh pr view "$TASK_PR_NUMBER" --repo {repo} --json number,title,headRefName,url,state,mergedAt
```

### B. Check PR for Unresolved Comments

For PR `$TASK_PR_NUMBER`, fetch all review comments and issue comments left by `{github_user}`:

```bash
gh pr view "$TASK_PR_NUMBER" --repo {repo} --json reviews,comments,headRefName
gh api repos/{repo}/pulls/"$TASK_PR_NUMBER"/comments
gh api repos/{repo}/issues/"$TASK_PR_NUMBER"/comments
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
   gh api repos/{repo}/issues/"$TASK_PR_NUMBER"/comments \
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

### E. Merged PR → Move Jira to Review (await Roi)

The pipeline never sets a Jira issue to "Done"/"Completed". When work is finished (PR merged), leave the issue in **"Review"** for Roi's decision — he is the only one who moves an issue to Completed.

1. **Transition Jira to "Review"** (NOT Done/Completed):

   **Tool:** `mcp__atlassian__getTransitionsForJiraIssue` to find the "Review" transition ID, then `mcp__atlassian__transitionJiraIssue`. If the issue is already in "Review", leave it.

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

---

### F. Review gate → approve label → auto-merge of integration-branch PRs

Auto-merge into a safe integration branch is **gated on review**: the `poll-github.sh` cron merges a PR into the repo's `base_branch` only when ALL hold — CI is green **if the repo is CI-gated** (Vercel status == `success`), the **`reviewed-ok`** label is present, there is **no `danger` label**, and **no open `CHANGES_REQUESTED` review**. A freshly-opened PR has no `reviewed-ok` label, so it will **not** merge until the review below runs. You never merge these by hand.

A PR is auto-merge-eligible two ways: **(a)** the repo has `auto_merge_when_green: true` (CI-gated — e.g. knesset-front), or **(b)** the linked Jira issue carries the **`auto-merge`** label (works even in repos with no CI, e.g. the Drupal knesset-data repo; CI-green not required, review still is). Both require the PR target the repo's `base_branch` (always `dev`).

**Review-and-approve step (run this for every PR you opened or pushed to):**

1. Determine whether this PR is auto-merge eligible:
   ```bash
   gh pr view "$TASK_PR_NUMBER" --repo {repo} --json baseRefName -q .baseRefName   # the PR's base
   jq -r --arg r "{repo}" '.repos[] | select(.github==$r) | "\(.auto_merge_when_green // false) \(.base_branch)"' {project_dir}/.jira-process.json
   # plus: does the Jira issue have the "auto-merge" label?
   ```
   Proceed if the PR's base equals the repo's `base_branch` (the safe branch, e.g. `dev`) **and** either `auto_merge_when_green` is `true` **or** the Jira issue `$TASK_KEY` has the `auto-merge` label. Otherwise (e.g. a plain `knesset-data` → `dev` PR with no `auto-merge` label, or any PR into `master`) **do nothing here** — Roi reviews and merges manually.

   **Sibling-PR gate (do NOT auto-approve a front PR while a paired Drupal PR awaits manual review):** if this same Jira issue `$TASK_KEY` also produced a PR in a repo that is **not** auto-merge (e.g. `knesset-data` Drupal, reviewed manually by Roi), then **do not add `reviewed-ok`** to the front PR — even if the front PR is clean. A front change paired with backend work must not merge ahead of Roi's manual review of the backend. Check for sibling PRs across the project's repos (e.g. `gh pr list --repo roikedem/knesset-data --search "$TASK_KEY" --state open`); if a manual-review sibling PR is still open, leave the front PR reviewed but **unlabeled**, and note in the Jira comment that it's held pending the backend PR. Re-run the approve step once the sibling is merged.

2. Run a fresh-eyes review of the PR diff — `/code-review` (correctness + security) plus the repo's `test_commands` (build + lint). You are an auditor, not the author: try to find problems.

3. **Decide and signal with a label** (the pipeline authors its own PRs, so a GitHub "Approve" review is not possible — GitHub forbids approving your own PR; the label is the approval signal):
   - **Clean** (no findings, checks green):
     ```bash
     gh pr edit "$TASK_PR_NUMBER" --repo {repo} --add-label "reviewed-ok"
     ```
     The poller merges it on the next cycle once Vercel is green.
   - **Findings found:** do **not** add the label. Either fix them yourself (PR Review → C, then re-review) or, for a risky/uncertain change, raise the block:
     ```bash
     gh pr edit "$TASK_PR_NUMBER" --repo {repo} --add-label "danger"
     ```
     and escalate to Roi. `danger` blocks auto-merge even if `reviewed-ok` is also present.
   - If you later push a fix to a PR that addresses your own findings, re-review before re-adding `reviewed-ok`.

What this means for you:
- After opening a `dev`-targeted PR, run the review-and-approve step. Do not block waiting for the Vercel build — once you've added `reviewed-ok`, the poller merges within a few minutes of the build going green. The merge later surfaces as a `github_pr_merged` task → step E.
- If a human leaves comments, address them (PR Review → C) and push; re-review and re-apply `reviewed-ok` once clean.
- **Never** open or merge a PR into a production/default branch (e.g. `master`) on the pipeline's own initiative. `dev` → `master` promotion is Roi's call.

> One-time setup per auto-merge repo: the `reviewed-ok` and `danger` labels must exist. `gh label create reviewed-ok --repo {repo} --color 0E8A16 --description "Pipeline review passed — eligible for auto-merge" 2>/dev/null` (and `danger --color B60205`). `gh pr edit --add-label` also creates a missing label on some gh versions, but create them explicitly to be safe.

---

## Exit Checklist

**Before ending the session, verify every applicable item:**

| # | Check | How to verify |
|---|---|---|
| 1 | Jira status is **"Review"** (always — never set Done/Completed; Roi decides that) | `mcp__atlassian__getJiraIssue` → `fields.status.name` |
| 2 | PR exists and is open | `gh pr view $TASK_PR_NUMBER --repo {repo}` |
| 3 | PR is linked in Jira Development panel | `mcp__atlassian__getJiraIssueRemoteIssueLinks` |
| 4 | Jira comment posted with PR link | `mcp__atlassian__getJiraIssue` → `fields.comment` |
| 5 | `$TASK_CONTEXT_FILE` status is `waiting for PR review` | `cat "$TASK_CONTEXT_FILE"` |

**If any check fails, fix it before exiting.**

Do not skip this checklist. The user will not review work that is not in "Review" status in Jira.
