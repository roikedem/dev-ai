#!/usr/bin/env bash
# Usage: write-main-switch.sh ON|OFF
VALUE="${1:?Usage: write-main-switch.sh ON|OFF}"
export GH_TOKEN=$(cat ~/.config/claude-agent-gh-token)
gh api --method PATCH repos/roikedem/dev-ai/actions/variables/MAIN_SWITCH \
  -f name=MAIN_SWITCH -f value="$VALUE"
echo "Main Switch set to $VALUE"
