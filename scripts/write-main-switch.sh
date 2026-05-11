#!/usr/bin/env bash
# Usage: write-main-switch.sh ON|OFF
VALUE="${1:?Usage: write-main-switch.sh ON|OFF}"
SWITCH_FILE="$HOME/.config/dev-ai-main-switch"
printf '%s\n' "$VALUE" > "$SWITCH_FILE"
echo "Main Switch set to $VALUE ($SWITCH_FILE)"
