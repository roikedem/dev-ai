# Testing phase — the tester's playbook

This is the canonical, standalone guide for the **testing phase** of every dev-ai task.
PROCESS-TASK.md (§ "Local environment + browser" and § "5. Test") points here. When the
two differ, **this file wins** for anything testing-related.

The same session that solves an issue also tests it. Testing is done against the **real
local app**, exercised through a **real browser** you drive via the **`playwright` MCP**
tools (navigate, click, type, snapshot/read the DOM, screenshot). The browser runs headless
on this host. Do NOT fake tests. Do NOT screenshot the login page and call it "the feature."

This phase is **project-agnostic** — read what THIS project declares in its
`.jira-process.json` (`local_urls`, `repos[]`, `test_commands`) and adapt.

---

## 1. Start the environment

Start only what the task touches:
- **Drupal backend** (project has ddev / `local_urls.backend`): `cd {project_dir} && ddev start`. Backend URL = `local_urls.backend`.
- **Next.js front** (project has a front and `local_urls.frontend`): `cd {project_dir}/front && npm install && (npm run dev &)` — serves `local_urls.frontend`. Wait until it responds before testing. (Drupal-only projects like pandit have no front — skip.)
- If neither URL is declared, there is no live UI to browser-test → fall back to `test_commands` only.

## 2. Test users — REUSE first, create only if needed (LOCAL ONLY)

There is a **shared, persistent registry of test users** for each project at
`{project_dir}/.dev-ai-test-users.txt` (gitignored — local only). It lists every test user
already in the dev env: email, password, and roles.

**Always reuse.** Do NOT create a new user every run.
1. Read `{project_dir}/.dev-ai-test-users.txt`. If a user with the role(s) this feature needs already exists, **use it** — don't create another.
2. Create a new user ONLY when actually needed: no existing user has the required role, or the feature needs multiple distinct users at once (e.g. an assigner + an assignee). Then:
   - `ddev drush user:create <name> --mail="<name>@roikedem.com" --password="<pick>"`, grant roles (`ddev drush user:role:add <role> <name>`), mark email verified if the app gates on it.
   - **Append the new user to `{project_dir}/.dev-ai-test-users.txt`** (email, password, roles). Keep this file accurate — if you reset a password (`ddev drush user:password <name> "<new>"`) or change roles, update the entry.
3. Keep a stable **admin** user (Drupal `administrator`) in the registry for controlling/inspecting data; reuse it.

Use **@roikedem.com** addresses (so app email can be captured — below). The registry is the source of truth across runs; treat it like shared state, not per-task scratch.

**Email-driven flows (password reset, email verification, notifications):** give the test user a **`tester*@roikedem.com`** address (e.g. `tester-$TASK_KEY-mgr@roikedem.com`). App mail to any `tester*@roikedem.com` is captured as JSON in `~/projects/team-emails/inbox/tester/` (SES→Lambda→SQS→poller, ~2 min). To test such a flow: trigger it in the app, read the newest file in `inbox/tester/` whose `to` matches your test address, extract the link/code from `body_text`, continue in the browser.

## 3. Log in through the browser

Using the `playwright` MCP: navigate to the login page (`{local_urls.frontend}/login` for the front; `{local_urls.backend}/user/login` for Drupal admin), fill email+password of the **role-appropriate** test user, submit, and confirm you're authenticated (you land on the dashboard, not back on `/login`).

## 4. Before-capture (before touching code)

- Identify the URL(s) and the exact on-screen element that shows the problem.
- Log in, navigate there, screenshot **the relevant element/section** (not the login page) → `$TASK_CONTEXT_DIRECTORY/before.png`.
- Create `$TASK_CONTEXT_DIRECTORY/index.html` (the **test report** — see §7) with the Before section filled, including the observed symptom.

**Screenshot framing (applies to every screenshot — before, steps, after):** crop **around the tested element with GENEROUS margins** — include the surrounding context (labels, the row/card it's in, nearby headers), not a tight box on the element alone. Tight crops lose information (the KNS-188 shots were too tight and cut off context). Prefer the element plus a healthy padding, or the whole panel/section it lives in. Save every screenshot **into `$TASK_CONTEXT_DIRECTORY`**, never into the project repo.

## 5. Write the test plan (for YOU to execute, not for Roi)

Write `$TASK_CONTEXT_DIRECTORY/testplan.txt` as numbered **executable** steps: which user/role to log in as, which URL, what to click/type, and the **expected on-screen result** per step. Example:
`1. Log in as tester-XXX@roikedem.com. 2. Open /dashboard/assignments. 3. Click "Add member". 4. Expect: dialog shows email+name+permissions fields. 5. Submit → expect new member appears in the list.`

Post the testplan as a Jira comment (`mcp__atlassian__addCommentToJiraIssue`).

## 6. Run the test plan in the real browser

- Execute each step via the playwright MCP: navigate, click, type, then **read the page (DOM snapshot / visible text) and ASSERT the expected result actually happened** — never assume; verify on screen.
- Capture a screenshot at each **significant** step (dialog opened, state after a click, the changed value, any error) → `step-1.png`, `step-2.png`, … in `$TASK_CONTEXT_DIRECTORY`, and add a step entry to the report (§7).
- Run the repo's `test_commands` (`test_commands.backend` / `frontend`, e.g. build + lint) and confirm they pass.
- Confirm the **original Jira symptom** is gone by observing the fixed screen.
- Record pass/fail per step (with what you saw, plus a screenshot of the failure) in the report.
- **On any step failure → go back to the solver, then back to testing.** Do NOT proceed, do NOT open/advance the PR, do NOT mark anything done. Return to PROCESS-TASK.md "§4 Solve the Issue", fix the root cause, then re-run the testplan **from the start** in the browser. Repeat until every step passes. The cycle is solve → test → (fail) → solve → test, and only a fully-green run exits the loop. Keep each failed attempt's screenshots in the report so the history is visible.

## 7. After-capture + HTML test report

- Via the playwright MCP, navigate to the **same screen/element** as the before-shot and screenshot the fixed state → `$TASK_CONTEXT_DIRECTORY/after.png` (same framing as before.png; never the login page).

### Where files go (strict)
**ALL test artifacts — every `.png` and `index.html` — live ONLY in `$TASK_CONTEXT_DIRECTORY` (`~/dev-context/$TASK_KEY/`).** Never write screenshots into the project repo (`~/projects/knesset-data/...` etc.) — that pollutes the working tree and is wrong. When you take a screenshot with the playwright MCP, give it a path **inside** `$TASK_CONTEXT_DIRECTORY`. If any stray `.png` ends up in the repo, move it into the context dir and remove it from the repo before committing.

### The report is a self-contained log
`$TASK_CONTEXT_DIRECTORY/index.html` is the full record of what you did: **every step you performed, in order, each with a timestamp, a plain description, expected-vs-observed, and its embedded screenshot** — Before → each step (including any failures and re-tests) → After. A reader should be able to follow the entire test visually without you present.

- **Use RELATIVE image paths only** — `src="before.png"`, `src="step-3.png"`. Never absolute paths (`/home/...`) or `file://` — those render as broken links. The HTML and the images sit in the same directory, so the bare filename is the correct `src`.
- One `<h3>` block per step: `Step N — <HH:MM:SS> — <description>`, then Expected/Observed, then `<img>`.

Skeleton:
```html
<!DOCTYPE html>
<html>
<head><meta charset="utf-8"><title>$TASK_KEY test report</title></head>
<body>
  <h1>$TASK_KEY: <issue title></h1>
  <h2>Before</h2>
  <p><strong>URL:</strong> <a href="<url>"><url></a> &middot; <strong>Taken:</strong> <HH:MM:SS></p>
  <p><strong>Observed symptom:</strong> <what the screen wrongly shows></p>
  <img src="before.png" alt="before" style="max-width:100%;border:1px solid #ccc">

  <h2>Test steps</h2>
  <h3>Step 1 — <HH:MM:SS> — <description of action></h3>
  <p><strong>Expected:</strong> … &middot; <strong>Observed:</strong> … &middot; <strong>Result:</strong> PASS|FAIL</p>
  <img src="step-1.png" alt="step 1" style="max-width:100%;border:1px solid #ccc">
  <!-- repeat per step; include failed attempts + the re-test after the solver fixed it -->

  <h2>After</h2>
  <p><strong>URL:</strong> <a href="<url>"><url></a> &middot; <strong>Taken:</strong> <HH:MM:SS></p>
  <img src="after.png" alt="after" style="max-width:100%;border:1px solid #ccc">
</body>
</html>
```

### Upload the report to Jira (required, after testing passes)
Once the testplan is fully green, attach the report **and its images** to the Jira issue so it's viewable there:
1. Upload `index.html` and every `.png` it references as attachments:
   `POST /rest/api/3/issue/$TASK_KEY/attachments` (via `mcp__atlassian__fetch`, `multipart/form-data`, header `X-Atlassian-Token: no-check`), one call per file.
2. Post a Jira comment that embeds the images inline so they render in-issue, e.g. `!before.png|thumbnail!`, `!step-1.png|thumbnail!`, …, `!after.png|thumbnail!`, with the step descriptions — and link the uploaded `index.html` as the full report.

Then continue with the PR / Jira-transition steps in PROCESS-TASK.md.

---

## Notes / gotchas (append findings from real runs here)

- The browser MCP is wired in `config/playwright-mcp.json` (headless system Chrome) and passed to the session via `--mcp-config` in `scripts/claude-jira-cron.sh`.
- Browser testing is turn-heavy; if a session is cut off mid-test it may finish the work but never transition Jira. (Tune `--max-turns` in the cron if this recurs.)
