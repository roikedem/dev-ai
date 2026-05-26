#!/usr/bin/env bash
# Source this at the start of every Claude session:
#   source ~/projects/dev-ai/scripts/session-setup.sh
#
# Sets all environment variables required for gh, Jira, and GitHub API calls.

# GitHub token — required before any `gh` command
export GH_TOKEN=$(cat ~/.config/claude-agent-gh-token)

# Auth mode: api_key uses ~/.config/anthropic-api-key; pro_plan uses OAuth session from `claude login`
_AUTH_MODE=$("$(dirname "${BASH_SOURCE[0]}")/read-auth-mode.sh" 2>/dev/null || echo "api_key")
if [[ "$_AUTH_MODE" == "api_key" ]]; then
    export ANTHROPIC_API_KEY=$(cat ~/.config/anthropic-api-key)
else
    unset ANTHROPIC_API_KEY
fi
unset _AUTH_MODE
