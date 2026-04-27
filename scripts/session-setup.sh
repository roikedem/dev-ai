#!/usr/bin/env bash
# Source this at the start of every Claude session:
#   source ~/projects/dev-ai/scripts/session-setup.sh
#
# Sets all environment variables required for gh, Jira, and GitHub API calls.

# GitHub token — required before any `gh` command
export GH_TOKEN=$(cat ~/.config/claude-agent-gh-token)
