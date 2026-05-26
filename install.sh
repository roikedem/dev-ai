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

ANTHROPIC_API_KEY_ENC="U2FsdGVkX18dLB88tn/qN/gwM73xqy9dcaHl3looSpnudQ/FdEJwPYlNbp9Mj/plWtXRMqpnu/LpzBBIpIRQnBeg2t555PlF33d2QQkG76C8HXjW6vwlDVuLcaYSEhvEjXDCdkZcJHZ/IbQNa1s98p+riBTIX2KXzBCx1x2/zCk="
GH_CLAUDE_TOKEN_ENC="U2FsdGVkX1/PTDks3NW5WKcSZafLq7XqB+fnxT1cYhjFoG6ZYhu88pOctodkVlRjnXRwNzE9MAevOsrZbd+tXw=="
JIRA_API_TOKEN_ENC="U2FsdGVkX18J52ezvw4m6x/CCKUMJC5wH4Cn+iXRIM6j4VYEByZG8D+hY/eBfUgGh20ZU1H8tcQWqjI7QOGLKluk6EASFCGw0UBY1yLiXW2nVqfGJC30Rnfuufovcc9lpY/5mpQ+U+wuhRFRESfJ2320ntuiEAVooXz+vkXDIyvDgPHKJ1jtllRMMSbiQjjD+XEMrZN4/pRhI+g4dIyuoRKPljVRP3p5/JEM65nQp5zRsjGGKOEwJBlyvq1SvfiGwdaCDNoF1oCz5XzbFHjqMKdJXg+FRrvkSOT61yFWvJs="
NEON_PARAMS_ENC="U2FsdGVkX1/nnggghHju3TvNQDmjt78SpsFiKQkkGu5W2q4QdgvIno042TjHOpudMJNSZoGFK9/OK6vYc4n9E1wDZpa5EHK/BpTK8O5a+1kCCV2yRf/4qxubDbIQY1sqMSgh8ikwkWNJ85eJBCupjc5NsLbvNfgRCx3SXITeGJlgrfTsPiYXDPdktYb3Qk1cdT1dh+Fv/cH2uvkEelFrY6sU+1elQBPhix7VUy26eJkGcT197CiIGPf3TEpZ3WhOov5CpKcp0MW9y9PYeJHCRg=="

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

printf '%s' "$JIRA_API_TOKEN" > "$HOME/.config/atlassian-api-token"
chmod 600 "$HOME/.config/atlassian-api-token"

printf '%s\n' "$NEON_PARAMS" > "$HOME/.config/dev-ai-neon-connection-params"
chmod 600 "$HOME/.config/dev-ai-neon-connection-params"

echo "Credential files written to ~/.config/"

# ── 6. GitHub credentials ────────────────────────────────────────────────────
step "Configuring git credentials for github.com"
git config --global credential.helper store
printf 'https://x-access-token:%s@github.com\n' "$GH_CLAUDE_TOKEN" > "$HOME/.git-credentials"
chmod 600 "$HOME/.git-credentials"
echo "git credentials written — HTTPS clones will authenticate automatically"

# gh auth login is optional (token may lack read:org scope but still works for git)
printf '%s' "$GH_CLAUDE_TOKEN" | gh auth login --with-token 2>&1 \
    || warn "gh auth login skipped — git clone will still work via ~/.git-credentials"

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
