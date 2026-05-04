#!/usr/bin/env bash
# Wrapper: reads the Neon connection URI from ~/.config/dev-ai-neon-connection-params
# and passes it to mcp-server-postgres so the URI is never stored in settings.json.
CONN_PARAMS="$HOME/.config/dev-ai-neon-connection-params"
[ -f "$CONN_PARAMS" ] || { echo "Missing $CONN_PARAMS" >&2; exit 1; }
set -a && source "$CONN_PARAMS" && set +a
exec /home/roi/.nvm/versions/node/v20.20.2/bin/mcp-server-postgres \
  "postgresql://$PGUSER:$PGPASSWORD@$PGHOST/$PGDATABASE?sslmode=$PGSSLMODE"
