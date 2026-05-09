# Cloud Agent Project Configuration

Each file here configures one target project for the cloud agent.
Filename: `<slug>.json` where slug is a short identifier (e.g. `kns.json`).

The cloud agent reads these files from GitHub on every run via the Contents API,
so changes take effect on the next cron tick without redeploying.

## Template

```json
{
  "slug": "kns",
  "jira_cloud_id": "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx",
  "jira_project_key": "KNS",
  "jira_assignee": "Claude Agent",
  "jira_user_mention": "[~accountid:xxxxxxxxxxxxxxxxxxxxxxxx]",
  "repos": [
    {"github": "owner/backend-repo", "default_branch": "main"},
    {"github": "owner/frontend-repo", "default_branch": "main"}
  ],
  "has_local_test_env": true
}
```

## Fields

| Field | Required | Description |
|---|---|---|
| `slug` | yes | Short identifier, matches filename |
| `jira_cloud_id` | yes | Jira Cloud ID (from Jira admin) |
| `jira_project_key` | yes | Jira project key (e.g. `KNS`) |
| `jira_assignee` | yes | Display name of the Claude Jira user |
| `jira_user_mention` | yes | `[~accountid:...]` for @-mentions in comments |
| `repos` | yes | Array of GitHub repos the cloud agent may modify |
| `has_local_test_env` | no | true = cloud agent may set `local-test-env` on complex tasks |

## Trigger Environment Variables

The CronCreate trigger must have these environment variables set:

| Variable | Source |
|---|---|
| `GH_TOKEN` | GitHub token for ClaudeCodeRoiAgent (`~/.github-claude-api-token`) |
| `ANTHROPIC_API_KEY` | Anthropic API key (`~/.config/anthropic-api-key`) |
| `JIRA_EMAIL` | Jira admin email (e.g. `roikedem+admin@gmail.com`) |
| `JIRA_API_TOKEN` | Jira API token (`~/.config/atlassian-api-token-admin`) |
| `PGHOST` | Neon PostgreSQL host |
| `PGUSER` | Neon PostgreSQL user |
| `PGPASSWORD` | Neon PostgreSQL password |
| `PGDATABASE` | Neon PostgreSQL database name |
| `DEV_AI_REPO` | This repo, e.g. `roikedem/dev-ai` |

All of these are already on your machine. Run `scripts/cloud-trigger-setup.sh` to print the
`trigger create` command with all values filled in.
