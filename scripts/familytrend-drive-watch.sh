#!/usr/bin/env bash
# Poll the FamilyTrend Drive folder-watch (imports new statement files).
# Vercel Hobby cron is daily-only, so this is the real trigger; it also keeps
# the free Supabase DB from auto-pausing.
set -euo pipefail
CREDS="$HOME/projects/team/secrets/creds.json"
SECRET=$(python3 -c "import json;d=json.load(open('$CREDS'));print([e['cron_secret'] for e in d['supabase.com'] if e.get('label')=='familytrend'][0])")
OUT=$(curl -sS -m 120 -w ' HTTP %{http_code}' -H "Authorization: Bearer $SECRET" https://familytrend.org/api/import/watch)
echo "[$(date '+%Y-%m-%d %H:%M:%S')] familytrend watch: $OUT"
[[ "$OUT" == *"HTTP 200" ]]
