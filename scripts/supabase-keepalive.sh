#!/usr/bin/env bash
CONN_PARAMS="$HOME/.config/dev-ai-neon-connection-params"
[ -f "$CONN_PARAMS" ] || { echo "Missing $CONN_PARAMS" >&2; exit 1; }
set -a && source "$CONN_PARAMS" && set +a

PGPASSWORD="$PGPASSWORD" psql \
  -h "$PGHOST" -U "$PGUSER" -d "$PGDATABASE" -p "$PGPORT" \
  -c "SELECT 1;" -q > /dev/null
echo "[$(date '+%Y-%m-%d %H:%M:%S')] supabase keepalive ok"
