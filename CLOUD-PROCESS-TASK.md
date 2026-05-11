# Cloud Agent Process

This is the playbook for the scheduled cloud Routine (`dev-ai-cloud-agent`).
It runs hourly with no local machine involved. All credentials are pre-loaded
in `/tmp/e.sh` by the trigger prompt — begin every Bash snippet with `source /tmp/e.sh`.

## Model Signature

End **every** Jira comment and GitHub PR comment with:

```
---
*Processed by Claude Sonnet 4.6 (cloud agent)*
```

---

## Environment

All credentials are in `/tmp/e.sh`. Verify at the start:

```bash
source /tmp/e.sh
: "${GH_TOKEN:?}" "${ANTHROPIC_API_KEY:?}" "${JIRA_EMAIL:?}" "${JIRA_API_TOKEN:?}"
: "${PGHOST:?}" "${PGUSER:?}" "${PGPASSWORD:?}" "${PGDATABASE:?}" "${DEV_AI_REPO:?}"
echo "credentials OK"
```

---

## Jira Helper

Base URL and auth used in every Jira call:

```bash
source /tmp/e.sh
JIRA_BASE="https://intotodev.atlassian.net/rest/api/3"
JIRA_AUTH="$JIRA_EMAIL:$JIRA_API_TOKEN"

jira_get()  { curl -sf -u "$JIRA_AUTH" -H "Accept: application/json" "$JIRA_BASE$1"; }
jira_post() { curl -sf -u "$JIRA_AUTH" -H "Accept: application/json" -H "Content-Type: application/json" -X POST  "$JIRA_BASE$1" -d "$2"; }
jira_put()  { curl -sf -u "$JIRA_AUTH" -H "Accept: application/json" -H "Content-Type: application/json" -X PUT   "$JIRA_BASE$1" -d "$2"; }
```

**Jira ADF comment body** (use this structure for every comment):

```json
{
  "body": {
    "type": "doc", "version": 1,
    "content": [{"type": "paragraph", "content": [{"type": "text", "text": "YOUR TEXT HERE"}]}]
  }
}
```

---

## GitHub Helper

```bash
source /tmp/e.sh
GH_API="https://api.github.com"
GH_HDR='-H "Authorization: Bearer $GH_TOKEN" -H "Accept: application/vnd.github+json" -H "X-GitHub-Api-Version: 2022-11-28"'

gh_get()  { curl -sf  -H "Authorization: Bearer $GH_TOKEN" -H "Accept: application/vnd.github+json" "$GH_API$1"; }
gh_post() { curl -sf  -H "Authorization: Bearer $GH_TOKEN" -H "Accept: application/vnd.github+json" -H "Content-Type: application/json" -X POST  "$GH_API$1" -d "$2"; }
gh_put()  { curl -sf  -H "Authorization: Bearer $GH_TOKEN" -H "Accept: application/vnd.github+json" -H "Content-Type: application/json" -X PUT   "$GH_API$1" -d "$2"; }
gh_patch(){ curl -sf  -H "Authorization: Bearer $GH_TOKEN" -H "Accept: application/vnd.github+json" -H "Content-Type: application/json" -X PATCH "$GH_API$1" -d "$2"; }
```

---

## Neon Helper

Save as `/tmp/neon_query.py`, then call: `python3 /tmp/neon_query.py "SELECT ..." '[]'`

```python
#!/usr/bin/env python3
import sys, json, base64, urllib.request, os

sql    = sys.argv[1]
params = json.loads(sys.argv[2]) if len(sys.argv) > 2 else []

host, user = os.environ['PGHOST'], os.environ['PGUSER']
password, database = os.environ['PGPASSWORD'], os.environ['PGDATABASE']

creds   = base64.b64encode(f"{user}:{password}".encode()).decode()
payload = json.dumps({"query": sql, "params": params}).encode()

req = urllib.request.Request(
    f"https://{host}/sql", data=payload,
    headers={"Authorization": f"Basic {creds}", "Content-Type": "application/json",
             "Neon-Connection-String": f"postgresql://{user}:{password}@{host}/{database}?sslmode=require"})
with urllib.request.urlopen(req) as r:
    print(r.read().decode())
```

---

## Setup: Load Project Configs

```bash
source /tmp/e.sh
curl -sf -H "Authorization: Bearer $GH_TOKEN" \
  "https://api.github.com/repos/$DEV_AI_REPO/contents/cloud-config" \
  | jq -r '.[] | select(.name | endswith(".json")) | .download_url' \
  | while read URL; do curl -sf "$URL"; echo; done
```

Parse each JSON object. For every subsequent step, iterate over all project configs.

---

## Phase 1: Apply Completed Batches

```bash
source /tmp/e.sh
python3 /tmp/neon_query.py \
  "SELECT id, task_key, cloud_batch_id, payload FROM tasks WHERE status='cloud_batch_pending'" '[]'
```

For each row, check Anthropic Batch status:

```python
#!/usr/bin/env python3
import anthropic, os, sys
client = anthropic.Anthropic(api_key=os.environ['ANTHROPIC_API_KEY'])
batch  = client.messages.batches.retrieve(sys.argv[1])
print(batch.processing_status)   # "in_progress" or "ended"
```

If `ended`: retrieve results and call **Apply Result** (below) for each succeeded request.

If `errored` or permanently failed:

```bash
source /tmp/e.sh
python3 /tmp/neon_query.py \
  "UPDATE tasks SET status='done', completed_at=NOW() WHERE id=\$1" "[$TASK_DB_ID]"
```

---

## Phase 2: Poll Jira for New Work

For each project config, search for open issues assigned to Claude without `local-dev-env`:

```bash
source /tmp/e.sh
JIRA_BASE="https://intotodev.atlassian.net/rest/api/3"
JQL="project=$PROJECT_KEY AND assignee=\"$JIRA_ASSIGNEE\" AND statusCategory != Done AND labels != \"local-dev-env\" ORDER BY updated DESC"
ENCODED=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))" "$JQL")
curl -sf -u "$JIRA_EMAIL:$JIRA_API_TOKEN" -H "Accept: application/json" \
  "$JIRA_BASE/search?jql=$ENCODED&maxResults=20&fields=summary,status,labels,comment,created"
```

For each issue returned, read its full details:

```bash
source /tmp/e.sh
curl -sf -u "$JIRA_EMAIL:$JIRA_API_TOKEN" -H "Accept: application/json" \
  "https://intotodev.atlassian.net/rest/api/3/issue/$KEY?fields=summary,description,status,labels,comment"
```

Decide if action is needed:

| Situation | Action |
|---|---|
| Status Open or In Progress, no Claude comment yet | Implement the issue |
| Status In Progress, newest non-Claude Jira comment is newer than newest Claude comment | Address the Jira comment |
| Status Review, GitHub PR has `CHANGES_REQUESTED` newer than newest Claude activity | Address PR review |
| Status Review, GitHub PR has unaddressed non-Claude comment newer than newest Claude activity | Address PR comment |
| Status Review, PR was merged | Transition to Done |
| Otherwise | Skip |

To find the last Claude comment: filter `fields.comment.comments` where `author.displayName == "$JIRA_ASSIGNEE"`, take the latest `created` timestamp.

---

## Phase 3: Poll GitHub for PR Merges and Feedback

For each repo in each project config:

```bash
source /tmp/e.sh
# Recently merged PRs (last 2 hours, to overlap with hourly runs)
curl -sf -H "Authorization: Bearer $GH_TOKEN" \
  "https://api.github.com/repos/$REPO/pulls?state=closed&per_page=10" \
  | jq -c '.[] | select(.merged_at != null) | select(.merged_at > (now - 7200 | todate))'

# Open PRs — check for reviews and comments
curl -sf -H "Authorization: Bearer $GH_TOKEN" \
  "https://api.github.com/repos/$REPO/pulls?state=open&per_page=20"
```

For each open PR, check reviews and comments from non-agent users:

```bash
source /tmp/e.sh
curl -sf -H "Authorization: Bearer $GH_TOKEN" \
  "https://api.github.com/repos/$REPO/pulls/$PR_NUM/reviews"

curl -sf -H "Authorization: Bearer $GH_TOKEN" \
  "https://api.github.com/repos/$REPO/pulls/$PR_NUM/comments"

curl -sf -H "Authorization: Bearer $GH_TOKEN" \
  "https://api.github.com/repos/$REPO/issues/$PR_NUM/comments"
```

Merge findings into the actionable task list from Phase 2.

---

## Phase 4: Build Batch Requests

For each actionable task **without** the `Urgent` label, build one batch request.

### Fetch Code Context

```bash
source /tmp/e.sh
# File tree
curl -sf -H "Authorization: Bearer $GH_TOKEN" \
  "https://api.github.com/repos/$REPO/git/trees/$DEFAULT_BRANCH?recursive=1" \
  | jq -r '[.tree[] | select(.type=="blob") | .path] | .[:300] | .[]'

# File content (base64 decode)
curl -sf -H "Authorization: Bearer $GH_TOKEN" \
  "https://api.github.com/repos/$REPO/contents/$PATH?ref=$DEFAULT_BRANCH" \
  | jq -r '.content' | base64 -d
```

Include at most 15 relevant files (files mentioned in the issue, recently changed files).

### Batch Request Object

```python
{
  "custom_id": f"{task_key}-{timestamp}",
  "params": {
    "model": "claude-sonnet-4-6",
    "max_tokens": 8192,
    "messages": [{"role": "user", "content": PROMPT}]
  }
}
```

### Batch Prompt Template

```
You are a software development agent implementing a Jira issue via the GitHub API.
You cannot run commands locally. Output your implementation in the exact XML format below.

## Jira Issue: {KEY}
Summary: {SUMMARY}
Status: {STATUS}

Description:
{DESCRIPTION}

{COMMENTS_IF_ANY}

## Repository: {REPO} (default branch: {DEFAULT_BRANCH})
File tree:
{FILE_TREE}

Relevant file contents:
{FILE_CONTENTS}

---

Decide if this task is complex or sensitive enough to warrant local testing.
Set <needs_local_testing> accordingly.

Output EXACTLY this XML structure:

<analysis>
What needs to change and why. Whether local testing is warranted and why.
</analysis>

<needs_local_testing>true|false</needs_local_testing>

<git_branch>
{key-lowercase}-short-description
</git_branch>

<file_changes>
<file path="relative/path/to/file.ext">
COMPLETE file content — not a diff
</file>
</file_changes>

<commit_message>
{KEY}: what changed and why (under 72 chars)
</commit_message>

<pr_title>
{KEY}: title (under 70 chars)
</pr_title>

<pr_body>
## Summary
- bullet points

## Test Plan
- [ ] items
</pr_body>

<jira_comment>
Implemented in PR #[PR_NUMBER]: brief description.

---
*Processed by Claude Sonnet 4.6 (cloud agent)*
</jira_comment>

Rules:
- Provide COMPLETE file content for each changed file (not diffs)
- Branch name: lowercase, hyphens only, start with Jira key lowercased (e.g. kns-68-fix-login)
- If you cannot determine exact changes, leave <file_changes></file_changes> empty and explain in <analysis>
```

---

## Phase 5: Submit Batch

```python
#!/usr/bin/env python3
import anthropic, os, json, sys

client   = anthropic.Anthropic(api_key=os.environ['ANTHROPIC_API_KEY'])
requests = json.loads(sys.argv[1])   # list of request objects from Phase 4
batch    = client.messages.batches.create(requests=requests)
print(batch.id)
```

After submitting, record each task's batch ID in Neon:

```bash
source /tmp/e.sh
python3 /tmp/neon_query.py \
  "UPDATE tasks SET cloud_batch_id=\$1, cloud_batch_submitted_at=NOW(), status='cloud_batch_pending' WHERE id=\$2" \
  "[\"$BATCH_ID\", $TASK_DB_ID]"
```

---

## Phase 6: Process Urgent Tasks Synchronously

For tasks with the `Urgent` label, call the Messages API directly:

```python
import anthropic, os
client = anthropic.Anthropic(api_key=os.environ['ANTHROPIC_API_KEY'])
msg = client.messages.create(
    model="claude-sonnet-4-6",
    max_tokens=8192,
    messages=[{"role": "user", "content": PROMPT}]
)
print(msg.content[0].text)
```

Then apply the result immediately using **Apply Result** below.

---

## Apply Result

Parse the XML output from a completed batch or synchronous call, then apply it.

### Parse Output

```python
import re, base64, json

def extract(text, tag):
    m = re.search(rf'<{tag}>(.*?)</{tag}>', text, re.DOTALL)
    return m.group(1).strip() if m else None

def extract_files(text):
    return {m.group(1): m.group(2).strip()
            for m in re.finditer(r'<file path="([^"]+)">(.*?)</file>', text, re.DOTALL)}
```

### 1. Transition Jira to In Progress (if not already)

```bash
source /tmp/e.sh
JIRA_BASE="https://intotodev.atlassian.net/rest/api/3"

# Get available transitions
TRANSITIONS=$(curl -sf -u "$JIRA_EMAIL:$JIRA_API_TOKEN" -H "Accept: application/json" \
  "$JIRA_BASE/issue/$KEY/transitions")

# Find the "In Progress" transition ID and apply it
IN_PROGRESS_ID=$(echo "$TRANSITIONS" | jq -r '.transitions[] | select(.name | ascii_downcase | contains("progress")) | .id' | head -1)
curl -sf -u "$JIRA_EMAIL:$JIRA_API_TOKEN" -H "Content-Type: application/json" -X POST \
  "$JIRA_BASE/issue/$KEY/transitions" \
  -d "{\"transition\": {\"id\": \"$IN_PROGRESS_ID\"}}"
```

### 2. Create Branch

```bash
source /tmp/e.sh
SHA=$(curl -sf -H "Authorization: Bearer $GH_TOKEN" \
  "https://api.github.com/repos/$REPO/git/refs/heads/$DEFAULT_BRANCH" | jq -r '.object.sha')

curl -sf -X POST -H "Authorization: Bearer $GH_TOKEN" \
  -H "Content-Type: application/json" \
  "https://api.github.com/repos/$REPO/git/refs" \
  -d "{\"ref\": \"refs/heads/$BRANCH\", \"sha\": \"$SHA\"}"
```

### 3. Write Each File

```bash
source /tmp/e.sh
# Base64-encode file content
CONTENT_B64=$(python3 -c "
import base64, sys
content = sys.stdin.read()
print(base64.b64encode(content.encode()).decode())
" << 'FILECONTENT'
[paste file content here]
FILECONTENT
)

# Get existing file SHA if file already exists (required for update)
EXISTING=$(curl -sf -H "Authorization: Bearer $GH_TOKEN" \
  "https://api.github.com/repos/$REPO/contents/$PATH?ref=$BRANCH" 2>/dev/null)
FILE_SHA=$(echo "$EXISTING" | jq -r '.sha // empty')

PAYLOAD="{\"message\": \"$COMMIT_MSG\", \"content\": \"$CONTENT_B64\", \"branch\": \"$BRANCH\""
[ -n "$FILE_SHA" ] && PAYLOAD="$PAYLOAD, \"sha\": \"$FILE_SHA\""
PAYLOAD="$PAYLOAD}"

curl -sf -X PUT -H "Authorization: Bearer $GH_TOKEN" \
  -H "Content-Type: application/json" \
  "https://api.github.com/repos/$REPO/contents/$PATH" \
  -d "$PAYLOAD"
```

### 4. Create PR

```bash
source /tmp/e.sh
PR=$(curl -sf -X POST -H "Authorization: Bearer $GH_TOKEN" \
  -H "Content-Type: application/json" \
  "https://api.github.com/repos/$REPO/pulls" \
  -d "{\"title\": \"$PR_TITLE\", \"body\": \"$PR_BODY\", \"head\": \"$BRANCH\", \"base\": \"$DEFAULT_BRANCH\"}")
PR_NUMBER=$(echo "$PR" | jq -r '.number')
PR_URL=$(echo "$PR" | jq -r '.html_url')
```

### 5. Post Jira Comment (replace [PR_NUMBER] with actual number)

```bash
source /tmp/e.sh
JIRA_BASE="https://intotodev.atlassian.net/rest/api/3"
COMMENT_TEXT="Implemented in PR #$PR_NUMBER: brief summary.\n\n---\n*Processed by Claude Sonnet 4.6 (cloud agent)*"

curl -sf -u "$JIRA_EMAIL:$JIRA_API_TOKEN" -H "Content-Type: application/json" -X POST \
  "$JIRA_BASE/issue/$KEY/comment" \
  -d "{\"body\": {\"type\": \"doc\", \"version\": 1, \"content\": [{\"type\": \"paragraph\", \"content\": [{\"type\": \"text\", \"text\": \"$COMMENT_TEXT\"}]}]}}"
```

### 6. Link PR to Jira

```bash
source /tmp/e.sh
JIRA_BASE="https://intotodev.atlassian.net/rest/api/3"
curl -sf -u "$JIRA_EMAIL:$JIRA_API_TOKEN" -H "Content-Type: application/json" -X POST \
  "$JIRA_BASE/issue/$KEY/remotelink" \
  -d "{\"object\": {\"url\": \"$PR_URL\", \"title\": \"PR: $PR_TITLE\", \"icon\": {\"url16x16\": \"https://github.com/favicon.ico\"}}}"
```

### 7. Transition Jira to Review

```bash
source /tmp/e.sh
JIRA_BASE="https://intotodev.atlassian.net/rest/api/3"
TRANSITIONS=$(curl -sf -u "$JIRA_EMAIL:$JIRA_API_TOKEN" -H "Accept: application/json" \
  "$JIRA_BASE/issue/$KEY/transitions")
REVIEW_ID=$(echo "$TRANSITIONS" | jq -r '.transitions[] | select(.name | ascii_downcase | contains("review")) | .id' | head -1)
curl -sf -u "$JIRA_EMAIL:$JIRA_API_TOKEN" -H "Content-Type: application/json" -X POST \
  "$JIRA_BASE/issue/$KEY/transitions" \
  -d "{\"transition\": {\"id\": \"$REVIEW_ID\"}}"
```

### 8. If needs_local_testing AND project has_local_test_env

Add `local-test-env` label to the Jira issue:

```bash
source /tmp/e.sh
JIRA_BASE="https://intotodev.atlassian.net/rest/api/3"
curl -sf -u "$JIRA_EMAIL:$JIRA_API_TOKEN" -H "Content-Type: application/json" -X PUT \
  "$JIRA_BASE/issue/$KEY" \
  -d '{"update": {"labels": [{"add": "local-test-env"}]}}'
```

### 9. Mark Neon Task Done

```bash
source /tmp/e.sh
python3 /tmp/neon_query.py \
  "UPDATE tasks SET status='done', completed_at=NOW() WHERE id=\$1" "[$TASK_DB_ID]"
```

---

## Handling PR Feedback (Jira comment or GitHub review requesting changes)

1. Fetch the full Jira issue and PR details
2. Read the comment/review requesting changes
3. Transition Jira → **In Progress**:
   ```bash
   source /tmp/e.sh
   # (same transition call as step 1 in Apply Result above)
   ```
4. Build batch prompt (same template as Phase 4) but include:
   - Current branch name (not a new one)
   - Existing file contents from that branch
   - The feedback to address
5. Submit as batch (or synchronous if Urgent)
6. Apply new file changes as additional commits to the **existing** branch
7. Reply to the GitHub comment/review referencing the new commit:
   ```bash
   source /tmp/e.sh
   curl -sf -X POST -H "Authorization: Bearer $GH_TOKEN" \
     -H "Content-Type: application/json" \
     "https://api.github.com/repos/$REPO/issues/$PR_NUM/comments" \
     -d "{\"body\": \"Addressed in <commit_sha>: brief explanation.\n\n---\n*Processed by Claude Sonnet 4.6 (cloud agent)*\"}"
   ```
8. Transition Jira back to **Review**

---

## Handling Merged PR

```bash
source /tmp/e.sh
JIRA_BASE="https://intotodev.atlassian.net/rest/api/3"
TRANSITIONS=$(curl -sf -u "$JIRA_EMAIL:$JIRA_API_TOKEN" -H "Accept: application/json" \
  "$JIRA_BASE/issue/$KEY/transitions")
DONE_ID=$(echo "$TRANSITIONS" | jq -r '.transitions[] | select(.name | ascii_downcase | contains("done")) | .id' | head -1)
curl -sf -u "$JIRA_EMAIL:$JIRA_API_TOKEN" -H "Content-Type: application/json" -X POST \
  "$JIRA_BASE/issue/$KEY/transitions" \
  -d "{\"transition\": {\"id\": \"$DONE_ID\"}}"
```

Then mark the Neon task done.

---

## Jira Status Rules (strict)

- **In Progress**: set when you start working on an issue or addressing feedback
- **Review**: set **only** after a PR URL is confirmed open
- **In Progress again**: set when new human feedback arrives and you start addressing it
- **Done**: set only after PR is confirmed merged

Never transition to Review unless `$PR_URL` is a real open PR URL.
