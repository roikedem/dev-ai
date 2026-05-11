#!/usr/bin/env bash
export GH_TOKEN=$(cat ~/.config/claude-agent-gh-token)
gh api repos/roikedem/dev-ai/actions/variables/MAIN_SWITCH --jq .value
