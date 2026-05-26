# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Repo Is

`dev-ai` is a cron-driven automation harness that runs Claude Code as an autonomous agent to handle Jira issues and GitHub PR feedback. Claude is never invoked by a human during normal operation — the cron scripts do it.

## How the Automation Works

Three cron jobs run every 5 minutes per project:

1. **`poll-jira.sh <project-dir>`** — calls Jira REST API, pushes new tasks to the Neon-backed queue
2. **`poll-github.sh <project-dir>`** — calls GitHub API, pushes new PR events to the Neon-backed queue
3. **`claude-jira-cron.sh <project-dir>`** — if queue is non-empty and `MAIN_SWITCH=ON`, pops one task, exports it as env vars, and invokes Claude with `--dangerously-skip-permissions --output-format json -p "Follow the Entry Point section in .../PROCESS-TASK.md."`

The queue lives in a shared Neon PostgreSQL `tasks` table, keyed by `(project_dir, dedup_key)`. Connection params come from `~/.config/dev-ai-neon-connection-params` (sourced as `PG*` env vars). All queue ops go through `scripts/queue.sh`.

Claude processes **one task per session**. After finishing, it exits and the next cron tick picks up the next queue item.

## Key Scripts

| Script | Purpose |
|---|---|
| `scripts/claude-jira-cron.sh` | Main entry point — acquires lock, pops queue, runs Claude |
| `scripts/poll-jira.sh` | Polls Jira for new issues and comments |
| `scripts/poll-github.sh` | Polls GitHub for PR comments, reviews, and merges |
| `scripts/queue.sh` | Queue backed by Neon PostgreSQL. Operations: `push`, `pop`, `count`, `peek`, `done`, `requeue`, `recover` |
| `scripts/seal-credentials.sh` | Encrypts local credential files with a passphrase and patches the blobs into `install.sh` for distribution to new machines |
| `scripts/install.sh` (repo root) | One-shot machine setup: installs deps, decrypts credentials, clones repo, verifies Neon |
| `scripts/session-setup.sh` | Sets `GH_TOKEN`; sets `ANTHROPIC_API_KEY` or unsets it based on auth mode |
| `scripts/screenshot.js` | Puppeteer screenshot of a CSS selector: `node screenshot.js <url> <selector> <out.png>` |
| `scripts/generate-report.sh` | Reads JSON from stdin, writes HTML report with embedded before/after screenshots |
| `scripts/send-email.sh` | Sends HTML email via `msmtp` |
| `scripts/cron-setup.sh` | One-time per-project setup: creates dirs, gitignore entries, installs Puppeteer, prints crontab lines |
| `scripts/read-main-switch.sh` | Reads `MAIN_SWITCH` GitHub Actions variable from `roikedem/dev-ai` |
| `scripts/write-main-switch.sh` | Sets `MAIN_SWITCH` to ON or OFF |
| `scripts/read-auth-mode.sh` | Reads auth mode from `~/.config/dev-ai-auth-mode` (defaults to `api_key`) |
| `scripts/write-auth-mode.sh` | Sets auth mode to `api_key` or `pro_plan` |

## Process Documents (Claude's Playbooks)

- **`PROCESS-TASK.md`** — the active playbook. Claude reads this on every invocation. Describes the full workflow: session setup → route by `$TASK_TYPE` → solve/test/commit/PR → exit checklist.
- **`JIRA-PROCESS.md`** — older multi-task process guide. Still useful as reference; superseded by `PROCESS-TASK.md` for cron-driven single-task sessions.
- **`JIRA-REPORT.md`** — instructions for generating client reports (JQL → JSON → `generate-report.sh` → `send-email.sh`).

## Per-Project Configuration

Each target project needs a `.jira-process.json` file with placeholders that `PROCESS-TASK.md` and `JIRA-PROCESS.md` reference:

```json
{
  "jira_cloud_id": "...",
  "jira_project_key": "ABC",
  "jira_assignee": "Claude Agent display name",
  "jira_user_mention": "[~accountid:...]",
  "github_user": "reviewer-username",
  "repos": [
    {"github": "owner/repo", "local": "/path/to/repo"},
    {"github": "owner/frontend-repo", "local": "/path/to/repo/frontend-submodule"}
  ],
  "default_branch": "main",
  "backup_command": "...",
  "restore_command": "...",
  "test_commands": { "backend": "...", "frontend": "..." }
}
```

## Credentials (machine-level)

| File | Used by |
|---|---|
| `~/.config/claude-agent-gh-token` | `session-setup.sh` (`GH_TOKEN`), `poll-github.sh` |
| `~/.config/anthropic-api-key` | `session-setup.sh` (`ANTHROPIC_API_KEY`) |
| `~/.config/atlassian-api-token` | `poll-jira.sh` (Jira REST API basic auth — `roikedem+claudecode@gmail.com` / Claude Code Roi's Agent) |
| `~/.config/dev-ai-neon-connection-params` | `queue.sh` (sourced to set `PGHOST`/`PGUSER`/`PGPASSWORD`/`PGDATABASE`) |

The `gh` CLI must be authenticated as `ClaudeCodeRoiAgent`:
```bash
gh auth switch --user ClaudeCodeRoiAgent
```

## Task Context Directory

Each task gets a working directory at `~/dev-context/$TASK_KEY/`:

- `context.txt` — state machine for the task (`Status: in progress | waiting for PR review | waiting for user | done`)
- `before.png` / `after.png` — screenshots taken before and after the fix
- `index.html` — HTML doc linking the screenshots with URL and timestamp
- `testplan.txt` — written before committing; also posted as a Jira comment

After a PR merges, the directory is moved to `~/dev-context/archive/`.

## Main Switch

The automation can be paused globally without editing crontab:

```bash
# Pause all automation
scripts/write-main-switch.sh OFF

# Resume
scripts/write-main-switch.sh ON
```

The value is stored as a GitHub Actions variable (`MAIN_SWITCH`) in `roikedem/dev-ai`. `claude-jira-cron.sh` reads it before invoking Claude.

## Setting Up a New Project

```bash
~/projects/dev-ai/scripts/cron-setup.sh /path/to/project
# Then add the printed crontab lines via: crontab -e
```

## Task Types and Environment Variables

When Claude is invoked, these are set:

| Variable | Content |
|---|---|
| `$TASK_TYPE` | `jira_issue`, `jira_comment`, `github_pr_comment`, `github_pr_review`, `github_pr_merged` |
| `$TASK_KEY` | Jira issue key (e.g. `KNS-68`) |
| `$TASK_PR_NUMBER` | PR number (GitHub tasks) |
| `$TASK_BRANCH` | Branch name |
| `$TASK_CONTEXT_FILE` | Path to `~/dev-context/$TASK_KEY/context.txt` |
| `$TASK_CONTEXT_DIRECTORY` | Path to `~/dev-context/$TASK_KEY/` |
| `$GH_TOKEN` | GitHub token — do not override |

## Logs

Per-project logs in `<project-dir>/logs/`:
- `claude-jira.log` — Claude invocations, token usage, exit codes
- `poll-jira.log` — Jira polling results
- `poll-github.log` — GitHub polling results
