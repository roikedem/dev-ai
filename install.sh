#!/usr/bin/env bash
# One-shot machine setup for the dev-ai automation host.
# Installs all dependencies, decrypts and writes credential files,
# clones repos, sets up Node/Puppeteer.
#
# Usage:
#   chmod +x install.sh && ./install.sh
#
# To update credentials: run scripts/seal-credentials.sh on the source machine.

set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# CREDENTIALS (AES-256-CBC encrypted — run scripts/seal-credentials.sh to update)
# ─────────────────────────────────────────────────────────────────────────────

ANTHROPIC_API_KEY_ENC="U2FsdGVkX1+L1POABMdbUvHgK9uZJ0AnVjLPhhTo2rlXonXPqu5UpAlGXrwlkGXV3PgVxAPTHrrZkIeTKk2AJ5e5pCSgp19DG2BVXjB9PxK6j65aihErSjfiOWIITu+NRCgNg5OWs7jnFThIu1Kj7wGs7wadhI6hdqctS5Ws/dI="
GH_CLAUDE_TOKEN_ENC="U2FsdGVkX1+5tnbhWI8T029HyX2xHd2KTV9Yh22o14UQ+a2bmD2p44UYklvmrjEUJ+RoBOfh80V6ef+mTYq/Kg=="
JIRA_API_TOKEN_ENC="U2FsdGVkX1820/zTE/Xd2Q2vVWNJR25e42MCCZFPM1w90agh6oEo2XUqpxCOtaEHVbGFQacFAVX32/9FgSNtC99x6bjkhuvVxV1+pWBnVD1/jEE9m67rLIxddJ10IpySl2LbcZcWrHZ//N55mWMK/L0Y3TDvpUWEgc681amEz+R5fp2nZD2rpyYTFrS0XUMjjMd94m9eqdS+4tQSshBPpNWmDLWle6BLW88NNkwl2RGnxotX6iSOaq91C06Zj2/6XIoRLOBcqbq9RUBiYrxZ3qt/lhradYhR8FH04G9Pww4="
NEON_PARAMS_ENC="U2FsdGVkX1/Gzlj0zWGQc8LS7fks5lC1fGVUsCWuiApQfd9tjjM5zK4P7cM4/ciOSWeP5xcLcCfBWOp/JLDP/lfiXJr02EZ2ryj4iXX5bpUVflztmFmPLyLk0HUp3JlYpbCEElcVUfmyM0nHFF390EV96B0bw8RiVU9XMVJRyfibnvtSWroBfV5nM9WPPECCliEMvLQiZg7y310AkznNjWksC/U/CG03xOO0mZlmRI4VF4VAYaWt0c5p1bkf9lq06Br91jz3MiFDqVKL125paw=="

# ─────────────────────────────────────────────────────────────────────────────

DEV_AI_REPO="https://github.com/roikedem/dev-ai.git"
DEV_AI_DIR="$HOME/projects/dev-ai"

GREEN="\033[0;32m"; YELLOW="\033[1;33m"; RESET="\033[0m"
step() { echo -e "\n${GREEN}▶ $*${RESET}"; }
warn() { echo -e "${YELLOW}⚠ $*${RESET}"; }

# Check credentials are sealed
if [ -z "$ANTHROPIC_API_KEY_ENC" ]; then
    echo "ERROR: credentials not sealed yet."
    echo "Run scripts/seal-credentials.sh on the source machine first."
    exit 1
fi

# Prompt for passphrase and decrypt
echo ""
read -rs -p "Encryption passphrase: " PASSPHRASE; echo
PASSPHRASE=$(printf '%s' "$PASSPHRASE" | tr -d '\r')  # strip stray CR (WSL terminals)

dec() {
    printf '%s' "$1" | openssl enc -d -aes-256-cbc -pbkdf2 -a -A -pass "pass:$PASSPHRASE" \
        || { echo "ERROR: decryption failed — wrong passphrase?" >&2; exit 1; }
}

step "Decrypting credentials"
ANTHROPIC_API_KEY=$(dec "$ANTHROPIC_API_KEY_ENC")
GH_CLAUDE_TOKEN=$(dec "$GH_CLAUDE_TOKEN_ENC")
JIRA_API_TOKEN=$(dec "$JIRA_API_TOKEN_ENC")
NEON_PARAMS=$(dec "$NEON_PARAMS_ENC")
echo "Decryption OK"

# ── 1. System packages ────────────────────────────────────────────────────────
step "Installing system packages"
sudo apt-get update -qq
sudo apt-get install -y -qq \
    curl git jq python3 python3-pip \
    postgresql-client \
    msmtp msmtp-mta \
    build-essential ca-certificates gnupg

# ── 2. Node.js via nvm ───────────────────────────────────────────────────────
step "Installing Node.js via nvm"
if [ ! -d "$HOME/.nvm" ]; then
    curl -sf https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash
fi
export NVM_DIR="$HOME/.nvm"
# nvm uses unbound variables internally — suspend strict mode around it
set +eu
[ -s "$NVM_DIR/nvm.sh" ] && source "$NVM_DIR/nvm.sh"
nvm install --lts
nvm use --lts
nvm alias default node
set -eu

# ── 3. Claude Code CLI ───────────────────────────────────────────────────────
step "Installing Claude Code CLI"
npm install -g @anthropic-ai/claude-code

# ── 4. GitHub CLI ────────────────────────────────────────────────────────────
step "Installing GitHub CLI (gh)"
if ! command -v gh &>/dev/null; then
    curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
        | sudo dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] \
https://cli.github.com/packages stable main" \
        | sudo tee /etc/apt/sources.list.d/github-cli.list > /dev/null
    sudo apt-get update -qq
    sudo apt-get install -y -qq gh
fi

# ── 5. Credential files ──────────────────────────────────────────────────────
step "Writing credential files"
mkdir -p "$HOME/.config"

printf '%s' "$ANTHROPIC_API_KEY" > "$HOME/.config/anthropic-api-key"
chmod 600 "$HOME/.config/anthropic-api-key"

printf '%s' "$GH_CLAUDE_TOKEN" > "$HOME/.config/claude-agent-gh-token"
chmod 600 "$HOME/.config/claude-agent-gh-token"

printf '%s' "$JIRA_API_TOKEN" > "$HOME/.config/atlassian-api-token-admin"
chmod 600 "$HOME/.config/atlassian-api-token-admin"

printf '%s\n' "$NEON_PARAMS" > "$HOME/.config/dev-ai-neon-connection-params"
chmod 600 "$HOME/.config/dev-ai-neon-connection-params"

echo "Credential files written to ~/.config/"

# ── 6. gh auth — log in as ClaudeCodeRoiAgent ────────────────────────────────
# Scripts use GH_TOKEN env var directly, so gh auth login is optional.
# Failure here is non-fatal — token scope may not satisfy gh's validation.
step "Authenticating gh CLI as ClaudeCodeRoiAgent (optional)"
printf '%s' "$GH_CLAUDE_TOKEN" | gh auth login --with-token 2>&1 \
    && gh auth status \
    || warn "gh auth login failed — scripts will use GH_TOKEN env var directly (this is fine)"

# ── 7. Clone dev-ai repo ─────────────────────────────────────────────────────
step "Cloning dev-ai repo"
mkdir -p "$HOME/projects"
if [ -d "$DEV_AI_DIR/.git" ]; then
    warn "dev-ai already cloned — pulling latest"
    git -C "$DEV_AI_DIR" pull
else
    git clone "$DEV_AI_REPO" "$DEV_AI_DIR"
fi

# ── 8. Install Puppeteer ─────────────────────────────────────────────────────
step "Installing Puppeteer"
cd "$DEV_AI_DIR"
npm install puppeteer

# ── 9. Verify Neon connection ────────────────────────────────────────────────
step "Verifying Neon connection"
# Source the params file we just wrote to set PG* env vars
set -a && source "$HOME/.config/dev-ai-neon-connection-params" && set +a
if psql -c "SELECT 1;" &>/dev/null; then
    echo "Neon connection OK"
else
    warn "Neon connection failed — check credentials"
fi

# ── 10. Verify Claude Code ───────────────────────────────────────────────────
step "Verifying Claude Code"
ANTHROPIC_API_KEY="$ANTHROPIC_API_KEY" claude --version

# ── Done ─────────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo -e "${GREEN}  Installation complete!${RESET}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo ""
echo "Next steps for each project:"
echo ""
echo "  1. Clone the project repo:"
echo "     git clone https://github.com/roikedem/<repo>.git ~/projects/<repo>"
echo ""
echo "  2. Run per-project setup:"
echo "     $DEV_AI_DIR/scripts/cron-setup.sh ~/projects/<repo>"
echo ""
echo "  3. Add crontab lines (crontab -e):"
echo "     */5 * * * * $DEV_AI_DIR/scripts/poll-jira.sh ~/projects/<repo>"
echo "     */5 * * * * $DEV_AI_DIR/scripts/poll-github.sh ~/projects/<repo>"
echo "     */5 * * * * $DEV_AI_DIR/scripts/claude-jira-cron.sh ~/projects/<repo>"
echo ""
echo "  4. Make sure .jira-process.json exists in the project root."
echo ""
