#!/usr/bin/env bash
# Local file takes precedence: echo OFF > ~/.config/dev-ai-main-switch
SWITCH_FILE="$HOME/.config/dev-ai-main-switch"
if [ -f "$SWITCH_FILE" ]; then
    cat "$SWITCH_FILE" | tr -d '[:space:]'
    echo
else
    echo "OFF"
fi
