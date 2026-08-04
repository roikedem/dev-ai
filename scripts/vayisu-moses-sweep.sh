#!/usr/bin/env bash
# TRIP-120: pings the Moses sweeper every minute so a stuck/dropped job
# recovers in ~60s instead of waiting for Vercel Hobby's once-daily cron.
SECRET_FILE="$HOME/.config/vayisu-cron-secret"
[ -f "$SECRET_FILE" ] || { echo "Missing $SECRET_FILE" >&2; exit 1; }
set -a && source "$SECRET_FILE" && set +a

curl -fsS -m 30 -H "Authorization: Bearer $CRON_SECRET" https://vayisu.com/api/moses/sweep >/dev/null
