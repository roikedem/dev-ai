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

## 2. Test users — you create them (LOCAL ONLY, like any real user)

Most features need login; different features need different roles.
- **Drupal admin** (to control/inspect data): `ddev drush user:create tester_admin --mail="tester_admin@roikedem.com" --password="<pick>"` then `ddev drush user:role:add administrator tester_admin`.
- **Feature users** (as many as the feature needs — e.g. an account manager + a plain member): create via the app's normal flow or `ddev drush user:create <name> --mail="<name>@roikedem.com" --password="<pick>"`, grant the required role (`drush user:role:add <role> <name>`), and mark the email verified if the app gates on it (set the verified field/status as a real user would have). Use **@roikedem.com** addresses.
- Record users + passwords in `$TASK_CONTEXT_DIRECTORY/test-users.txt` so later sessions reuse them. Reuse existing ones; reset a password with `ddev drush user:password <name> "<new>"`.

**Email-driven flows (password reset, email verification, notifications):** give the test user a **`tester*@roikedem.com`** address (e.g. `tester-$TASK_KEY-mgr@roikedem.com`). App mail to any `tester*@roikedem.com` is captured as JSON in `~/projects/team-emails/inbox/tester/` (SES→Lambda→SQS→poller, ~2 min). To test such a flow: trigger it in the app, read the newest file in `inbox/tester/` whose `to` matches your test address, extract the link/code from `body_text`, continue in the browser.

## 3. Log in through the browser

Using the `playwright` MCP: navigate to the login page (`{local_urls.frontend}/login` for the front; `{local_urls.backend}/user/login` for Drupal admin), fill email+password of the **role-appropriate** test user, submit, and confirm you're authenticated (you land on the dashboard, not back on `/login`).

## 4. Before-capture (before touching code)

- Identify the URL(s) and the exact on-screen element that shows the problem.
- Log in, navigate there, screenshot **the relevant element/section** (not the login page) → `$TASK_CONTEXT_DIRECTORY/before.png`.
- Create `$TASK_CONTEXT_DIRECTORY/index.html` (the **test report** — see §7) with the Before section filled, including the observed symptom.

## 5. Write the test plan (for YOU to execute, not for Roi)

Write `$TASK_CONTEXT_DIRECTORY/testplan.txt` as numbered **executable** steps: which user/role to log in as, which URL, what to click/type, and the **expected on-screen result** per step. Example:
`1. Log in as tester-XXX@roikedem.com. 2. Open /dashboard/assignments. 3. Click "Add member". 4. Expect: dialog shows email+name+permissions fields. 5. Submit → expect new member appears in the list.`

Post the testplan as a Jira comment (`mcp__atlassian__addCommentToJiraIssue`).

## 6. Run the test plan in the real browser

- Execute each step via the playwright MCP: navigate, click, type, then **read the page (DOM snapshot / visible text) and ASSERT the expected result actually happened** — never assume; verify on screen.
- Capture a screenshot at each **significant** step (dialog opened, state after a click, the changed value, any error) → `step-1.png`, `step-2.png`, … and add a "During" entry to the report (§7).
- Run the repo's `test_commands` (`test_commands.backend` / `frontend`, e.g. build + lint) and confirm they pass.
- Confirm the **original Jira symptom** is gone by observing the fixed screen.
- Record pass/fail per step (with what you saw) in the testplan; update the Jira comment. **If any step fails, fix and re-run — do not proceed with a failing testplan.**

## 7. After-capture + HTML test report

- Via the playwright MCP, navigate to the **same screen/element** as the before-shot and screenshot the fixed state → `$TASK_CONTEXT_DIRECTORY/after.png` (same framing as before.png; never the login page).
- Finish `$TASK_CONTEXT_DIRECTORY/index.html` so a reader can follow the whole test visually: **Before → each significant step (During) → After**, each with description, expected vs observed, and its image. Skeleton:

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
  <!-- one block per significant step -->
  <h3>Step N: <description></h3>
  <p><strong>Expected:</strong> … <strong>Observed:</strong> …</p>
  <img src="step-N.png" style="max-width:100%;border:1px solid #ccc">
  <h2>After</h2>
  <p><strong>URL:</strong> <a href="<url>"><url></a></p>
  <p><strong>Taken:</strong> <ISO 8601 timestamp></p>
  <img src="after.png" alt="after" style="max-width:100%;border:1px solid #ccc">
</body>
</html>
```

Then continue with the PR / Jira-transition steps in PROCESS-TASK.md.

---

## Notes / gotchas (append findings from real runs here)

- The browser MCP is wired in `config/playwright-mcp.json` (headless system Chrome) and passed to the session via `--mcp-config` in `scripts/claude-jira-cron.sh`.
- Browser testing is turn-heavy; if a session is cut off mid-test it may finish the work but never transition Jira. (Tune `--max-turns` in the cron if this recurs.)
