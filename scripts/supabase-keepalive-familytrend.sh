#!/usr/bin/env bash
# Keep the FamilyTrend Supabase project from auto-pausing (free tier pauses
# after ~7 days idle, which 500s every DB-backed page). A daily SELECT 1 counts
# as activity. Reads the session (5432) connection from the encrypted creds.
set -euo pipefail
CREDS="$HOME/projects/team/secrets/creds.json"
URL=$(python3 -c "import json;d=json.load(open('$CREDS'));print([e['session_url'] for e in d['supabase.com'] if e.get('label')=='familytrend'][0])")
psql "$URL" -c "SELECT 1;" -q >/dev/null
echo "[$(date '+%Y-%m-%d %H:%M:%S')] familytrend supabase keepalive ok"
