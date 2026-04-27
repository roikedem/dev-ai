## Generating a Client Report

When asked to generate a report of completed issues:

1. Fetch all Done issues via `mcp__atlassian__searchJiraIssuesUsingJql` with `status=Done`.

2. Build a JSON array of issue data:
   ```json
   [
     {"key":"PAN-XX","type":"Bug","summary":"...","resolved":"YYYY-MM-DD","description":"one sentence of what was fixed"},
     ...
   ]
   ```

3. Run the report generator — it automatically embeds before/after screenshots from `{project_dir}/docs/screenshots/{key}/` when they exist:
   ```bash
   echo '<json-array>' | ~/projects/dev-ai/scripts/generate-report.sh {project_dir} /tmp/pandit-report.html
   ```

4. Send by email:
   ```bash
   ~/projects/dev-ai/scripts/send-email.sh <recipient> "Pandit Project — Development Report" /tmp/pandit-report.html
   ```

