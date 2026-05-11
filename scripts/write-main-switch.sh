#!/usr/bin/env bash
# Usage: write-main-switch.sh ON|OFF
VALUE="${1:?Usage: write-main-switch.sh ON|OFF}"
[[ "$VALUE" == "ON" || "$VALUE" == "OFF" ]] || { echo "ERROR: value must be ON or OFF" >&2; exit 1; }

GH_TOKEN_FILE="$HOME/.config/claude-agent-gh-token"
[ -f "$GH_TOKEN_FILE" ] || GH_TOKEN_FILE="$HOME/.github-claude-api-token"
[ -f "$GH_TOKEN_FILE" ] || { echo "ERROR: missing gh token file" >&2; exit 1; }
TOKEN=$(cat "$GH_TOKEN_FILE" | tr -d '\r\n')

API_URL="https://api.github.com/repos/roikedem/dev-ai-switch/contents/main-switch"
SHA=$(curl -sf -H "Authorization: token $TOKEN" -H "Accept: application/vnd.github+json" \
  "$API_URL" | python3 -c "import sys,json; print(json.load(sys.stdin)['sha'])")
[ -n "$SHA" ] || { echo "ERROR: could not fetch current file SHA" >&2; exit 1; }

CONTENT=$(printf '%s\n' "$VALUE" | base64 -w 0)
RESULT=$(curl -sf -X PUT \
  -H "Authorization: token $TOKEN" \
  -H "Accept: application/vnd.github+json" \
  "$API_URL" \
  -d "{\"message\":\"chore: set MAIN_SWITCH to $VALUE\",\"content\":\"$CONTENT\",\"sha\":\"$SHA\"}")
echo "$RESULT" | python3 -c "import sys,json; d=json.load(sys.stdin); print('Main Switch set to $VALUE — commit:', d['commit']['sha'][:8])"
