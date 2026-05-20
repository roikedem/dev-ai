#!/usr/bin/env bash
# Reads credential files from this machine, encrypts them with a passphrase,
# and patches the encrypted values into ../install.sh.
# Run this once whenever credentials change.
# Usage: scripts/seal-credentials.sh

set -euo pipefail

DEV_AI_DIR="$(cd "$(dirname "$0")/.." && pwd)"
INSTALL_SH="$DEV_AI_DIR/install.sh"

[ -f "$INSTALL_SH" ] || { echo "ERROR: $INSTALL_SH not found"; exit 1; }

# Verify all credential files exist before asking for a passphrase
missing=0
for f in \
    "$HOME/.config/anthropic-api-key" \
    "$HOME/.config/atlassian-api-token" \
    "$HOME/.config/dev-ai-neon-connection-params"; do
    [ -f "$f" ] || { echo "ERROR: missing $f"; missing=1; }
done
# GH token: check both locations
GH_TOKEN_FILE="$HOME/.config/claude-agent-gh-token"
[ -f "$GH_TOKEN_FILE" ] || GH_TOKEN_FILE="$HOME/.github-claude-api-token"
[ -f "$GH_TOKEN_FILE" ] || { echo "ERROR: missing gh token (checked ~/.config/claude-agent-gh-token and ~/.github-claude-api-token)"; missing=1; }
[ "$missing" -eq 1 ] && exit 1

echo "All credential files found."
echo ""
read -rs -p "Choose an encryption passphrase: " PASSPHRASE; echo
read -rs -p "Confirm passphrase:               " PASSPHRASE2; echo
[ "$PASSPHRASE" = "$PASSPHRASE2" ] || { echo "ERROR: passphrases do not match"; exit 1; }
echo ""

enc() {
    # Encrypts stdin with AES-256-CBC + PBKDF2, outputs single-line base64
    openssl enc -aes-256-cbc -pbkdf2 -a -A -salt -pass "pass:$PASSPHRASE"
}

echo "Encrypting credentials..."

ANTHROPIC_ENC=$(cat "$HOME/.config/anthropic-api-key"          | tr -d '\r\n' | enc)
GH_TOKEN_ENC=$(cat "$GH_TOKEN_FILE"                            | tr -d '\r\n' | enc)
JIRA_ENC=$(cat "$HOME/.config/atlassian-api-token"              | tr -d '\r\n' | enc)

# Neon params — encrypt the whole file content as one blob
NEON_ENC=$(cat "$HOME/.config/dev-ai-neon-connection-params"   | enc)

# Patch install.sh — replace everything between the CREDENTIALS markers
TMPFILE=$(mktemp)
python3 - "$INSTALL_SH" "$ANTHROPIC_ENC" "$GH_TOKEN_ENC" "$JIRA_ENC" "$NEON_ENC" <<'PYEOF'
import sys, re

install_sh, anthropic, gh, jira, neon = sys.argv[1:]

with open(install_sh) as f:
    content = f.read()

block = f"""# ─────────────────────────────────────────────────────────────────────────────
# CREDENTIALS (AES-256-CBC encrypted — run scripts/seal-credentials.sh to update)
# ─────────────────────────────────────────────────────────────────────────────

ANTHROPIC_API_KEY_ENC="{anthropic}"
GH_CLAUDE_TOKEN_ENC="{gh}"
JIRA_API_TOKEN_ENC="{jira}"
NEON_PARAMS_ENC="{neon}"
"""

new_content = re.sub(
    r'# ─+\n# CREDENTIALS.*?# ─+\n\n.*?(?=\n# ──)',
    block,
    content,
    flags=re.DOTALL
)

with open(sys.argv[1], 'w') as f:
    f.write(new_content)
print("install.sh patched.")
PYEOF

# Self-test: verify decryption works before committing
echo "Verifying decryption..."
dec() { printf '%s' "$1" | openssl enc -d -aes-256-cbc -pbkdf2 -a -A -pass "pass:$PASSPHRASE"; }
dec "$ANTHROPIC_ENC" > /dev/null || { echo "ERROR: self-test failed — decryption broken"; exit 1; }
dec "$GH_TOKEN_ENC"  > /dev/null || { echo "ERROR: self-test failed — decryption broken"; exit 1; }
dec "$JIRA_ENC"      > /dev/null || { echo "ERROR: self-test failed — decryption broken"; exit 1; }
dec "$NEON_ENC"      > /dev/null || { echo "ERROR: self-test failed — decryption broken"; exit 1; }
echo "Self-test OK"

# Commit and push so the new machine always gets fresh blobs
echo ""
git -C "$DEV_AI_DIR" add install.sh
git -C "$DEV_AI_DIR" commit -m "chore: re-seal credentials in install.sh"
git -C "$DEV_AI_DIR" push
echo ""
echo "Done. install.sh sealed, committed, and pushed."
echo "On the new machine: git pull && ./install.sh"
