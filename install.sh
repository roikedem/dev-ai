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

ANTHROPIC_API_KEY_ENC="U2FsdGVkX1+U5GtcM8m2VZmTp65SRxXMb2YRlHlW1KN1FBY/EnXQaZ1xYx6IapK4hkfWIYnhy3GpDTrLGhf78Oze5osK5LzlheB/gNus1OFVPisaSOSbpKKYCd3PIVMrbH6DNImaxnkpntOii0KZCP+21AWSz5PCdzZ3qeOhDOc="
GH_CLAUDE_TOKEN_ENC="U2FsdGVkX18KakGj8mqRN76E6gXJ5pGq0y7yL1Ufam1+fQfNsddDXIiOlonM+Ta6u6z+A+sfIU7NJUWBIIWXvQ=="
JIRA_API_TOKEN_ENC="U2FsdGVkX1/JJZxeYDNXf2rYaMgn6riwig6Xezs3qDFEeux1TbhlP3FRJxOAhhe7bn42PtqGvdVJNqh4zSybIOYX1z/jAk5eWfm/e9mi5U+UIPz+apskejeSjGTM4n0OJel49soccMcvfqvWz0cHzMt/LrtDf7VIVroK6hdc3XgZj+BBmjuOwY94LcCwv2XrgLbBSlrOoF13hPlPEQJ89wKD3yju1kx5dC/IG58iXsGu4IzQQLSEJhIdTHG7Wmg1BFDHhyd+hT1nciP6btugABHgwh5/xVGD3yBJSgYzr/s="
NEON_PARAMS_ENC="U2FsdGVkX1/fi1INJGap3JlOblEJLgWz22MOoF6aUrEsZLb/qXhE4siSBKbSKN7w4VJ4iI44NtPvZzuBkvrs0R7FO5Qp/nZn8KEbzyoKDiGs4zIovYqeP/54LvWW0+FmgTcT3GKPfGpVkrtJy4OPWblypJfwN6rK7ps0NWwXZtA1FOB1LJpiFIkMjOcWgTWXQ/a6389UgYnFJ9FaFNmjTZ7eTr/E8rOr1CI2Tl+WQUAoYtcI0VUONajSE2VyXcgUtFD43zVJr/wXjxHuixK5Uw=="

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
    printf '%s' "$1" | openssl enc -d -aes-256-cbc -pbkdf2 -a -pass "pass:$PASSPHRASE" \
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
[ -s "$NVM_DIR/nvm.sh" ] && source "$NVM_DIR/nvm.sh"
nvm install --lts
nvm use --lts
nvm alias default node

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
step "Authenticating gh CLI as ClaudeCodeRoiAgent"
printf '%s' "$GH_CLAUDE_TOKEN" | gh auth login --with-token
gh auth status

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
