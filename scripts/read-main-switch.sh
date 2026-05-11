#!/usr/bin/env bash
_GH_TOKEN_FILE="$HOME/.config/claude-agent-gh-token"
[ -f "$_GH_TOKEN_FILE" ] || _GH_TOKEN_FILE="$HOME/.github-claude-api-token"
GH_TOKEN=$(cat "$_GH_TOKEN_FILE" | tr -d '\r\n') \
  gh api repos/roikedem/dev-ai/actions/variables/MAIN_SWITCH --jq .value
