#!/usr/bin/env bash
# Usage: write-auth-mode.sh api_key|pro_plan
VALUE="${1:?Usage: write-auth-mode.sh api_key|pro_plan}"
[[ "$VALUE" == "api_key" || "$VALUE" == "pro_plan" ]] || { echo "ERROR: value must be api_key or pro_plan" >&2; exit 1; }

echo -n "$VALUE" > "$HOME/.config/dev-ai-auth-mode"
echo "now: $("$(dirname "$0")/read-auth-mode.sh")"

if [[ "$VALUE" == "pro_plan" ]]; then
    echo "Reminder: run 'claude login' if you haven't authenticated your Pro plan account yet."
fi
