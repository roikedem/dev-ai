#!/usr/bin/env bash
AUTH_MODE_FILE="$HOME/.config/dev-ai-auth-mode"
if [ -f "$AUTH_MODE_FILE" ]; then
    cat "$AUTH_MODE_FILE" | tr -d '\r\n'
else
    echo -n "api_key"
fi
