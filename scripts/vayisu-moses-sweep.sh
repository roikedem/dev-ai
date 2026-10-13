#!/usr/bin/env bash
# TRIP-120: pings the Moses sweeper every minute so a stuck/dropped job
# recovers in ~60s instead of waiting for Vercel Hobby's once-daily cron.
# Secret: ~/.config/vayisu-cron-secret, else the italy-trip .env (present on
# both HA boxes, so an HA flip doesn't break this job).
SECRET_FILE="$HOME/.config/vayisu-cron-secret"
[ -f "$SECRET_FILE" ] || SECRET_FILE="$HOME/projects/italy-trip/.env"
[ -f "$SECRET_FILE" ] || { echo "Missing vayisu cron secret" >&2; exit 1; }
set -a && source "$SECRET_FILE" && set +a
[ -n "$CRON_SECRET" ] || { echo "No CRON_SECRET in $SECRET_FILE" >&2; exit 1; }

curl -fsS -m 30 -H "Authorization: Bearer $CRON_SECRET" https://vayisu.com/api/moses/sweep >/dev/null
