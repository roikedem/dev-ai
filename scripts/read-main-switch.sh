#!/usr/bin/env bash
GH_TOKEN_FILE="$HOME/.config/claude-agent-gh-token"
[ -f "$GH_TOKEN_FILE" ] || GH_TOKEN_FILE="$HOME/.github-claude-api-token"
[ -f "$GH_TOKEN_FILE" ] || { echo "ERROR: missing gh token file" >&2; exit 1; }
TOKEN=$(cat "$GH_TOKEN_FILE" | tr -d '\r\n')

curl -sf \
  -H "Authorization: token $TOKEN" \
  -H "Accept: application/vnd.github.raw" \
  "https://api.github.com/repos/roikedem/dev-ai-switch/contents/main-switch" \
  | tr -d '\r\n'
