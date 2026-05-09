#!/usr/bin/env bash
# Source this at the start of every Claude session:
#   source ~/projects/dev-ai/scripts/session-setup.sh
#
# Sets all environment variables required for gh, Jira, and GitHub API calls.

# GitHub token — check both locations (canonical: ~/.config/claude-agent-gh-token, legacy: ~/.github-claude-api-token)
_GH_TOKEN_FILE="$HOME/.config/claude-agent-gh-token"
[ -f "$_GH_TOKEN_FILE" ] || _GH_TOKEN_FILE="$HOME/.github-claude-api-token"
export GH_TOKEN=$(cat "$_GH_TOKEN_FILE" | tr -d '\r\n')
unset _GH_TOKEN_FILE

# Anthropic API key — enables pay-per-use billing, bypasses Claude.ai subscription cap
export ANTHROPIC_API_KEY=$(cat ~/.config/anthropic-api-key)
