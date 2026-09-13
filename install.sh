#!/usr/bin/env bash
# cmdctl installer
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INSTALL_BIN="${INSTALL_DIR:-$HOME/.local/bin}"

echo "cmdctl installer"
echo "================"
echo ""

# --- Prerequisites ---
echo "Checking prerequisites..."
missing=()
command -v bash  >/dev/null 2>&1 || missing+=("bash")
command -v curl  >/dev/null 2>&1 || missing+=("curl")
command -v jq    >/dev/null 2>&1 || missing+=("jq")
command -v node  >/dev/null 2>&1 || missing+=("node")

if (( ${#missing[@]} > 0 )); then
  echo "  Missing: ${missing[*]}"
  echo "  Install them and re-run."
  exit 1
fi

bash_major="${BASH_VERSINFO[0]}"
if (( bash_major < 4 )); then
  echo "  Bash ${BASH_VERSION} is too old. Need 4+."
  exit 1
fi

echo "  bash ${BASH_VERSION} ✓"
echo "  curl $(curl --version | head -1 | awk '{print $2}') ✓"
echo "  jq $(jq --version) ✓"
echo "  node $(node --version) ✓"
echo ""

# --- command-code ---
printf "  command-code: "
if command -v cmd >/dev/null 2>&1 || command -v commandcode >/dev/null 2>&1; then
  echo "found ✓"
else
  echo "NOT FOUND"
  echo ""
  echo "Install command-code first: npm i -g command-code"
  echo "Re-run this installer after."
  exit 1
fi
echo ""

# --- Install bin ---
echo "Installing to $INSTALL_BIN..."
mkdir -p "$INSTALL_BIN"
chmod +x "$SCRIPT_DIR/bin/cmdctl"
ln -sf "$SCRIPT_DIR/bin/cmdctl" "$INSTALL_BIN/cmdctl"
echo "  $INSTALL_BIN/cmdctl → $SCRIPT_DIR/bin/cmdctl ✓"
echo ""

# --- Ensure INSTALL_BIN is on PATH ---
if ! echo "$PATH" | tr ':' '\n' | grep -q "^${INSTALL_BIN}$"; then
  echo "  NOTE: $INSTALL_BIN is not on your PATH."
  echo "  Add to ~/.bashrc or ~/.zshrc:"
  echo "    export PATH=\"\$HOME/.local/bin:\$PATH\""
  echo ""
fi

# --- Migrate existing cmdusage accounts ---
CMDCTL_DIR="$HOME/.config/cmdctl"
ACCOUNTS_FILE="$CMDCTL_DIR/accounts.json"
mkdir -p "$CMDCTL_DIR"
OLD_ACCOUNTS="$HOME/.config/cmdusage/accounts.json"

if [[ -f "$OLD_ACCOUNTS" && ! -f "$ACCOUNTS_FILE" ]]; then
  cp "$OLD_ACCOUNTS" "$ACCOUNTS_FILE"
  echo "[cmdctl] Migrated accounts from $OLD_ACCOUNTS ✓"
elif [[ -f "$ACCOUNTS_FILE" ]]; then
  echo "[cmdctl] accounts.json already exists ✓"
else
  printf '{"accounts":[]}\n' > "$ACCOUNTS_FILE"
  echo "[cmdctl] Created empty accounts.json ✓"
fi

# Initialize state if needed
[[ -f "$CMDCTL_DIR/state.json" ]] || printf '{"current":null}\n' > "$CMDCTL_DIR/state.json"
echo ""

# --- Add shell alias ---
echo "Shell integration:"
echo ""
echo "  To auto-switch accounts when running 'cmd', add to ~/.bashrc or ~/.zshrc:"
echo ""
echo "    alias cmd='cmdctl run --'"
echo ""
echo "  This means 'cmd' will automatically:"
echo "    - pick the best account on launch"
echo "    - watch for quota exhaustion during the session"
echo "    - rotate to another account and resume if the limit is hit"
echo ""

# --- Install Stop hook ---
echo "Stop hook (recommended):"
echo ""
echo "  To get turn-boundary quota detection, run:"
echo ""
echo "    cmdctl install-hook"
echo ""
echo "  This modifies ~/.commandcode/settings.json"
echo ""

# --- Manual account setup ---
echo "Getting started:"
echo ""
echo "  For each Command Code account:"
echo "    1. cmd logout && cmd login"
echo "    2. cmdctl accounts add [optional-name]"
echo ""
echo "  Or bootstrap them all from an env file:"
echo "    cmdctl accounts env      # writes accounts.env"
echo "    cmdctl accounts import   # loads NAME=API_KEY lines"
echo ""
echo "  Then:"
echo "    cmdctl accounts ls     # verify"
echo "    cmdctl check           # probe all"
echo "    cmdctl status          # see current"
echo "    cmdctl dashboard       # accounts + agent usage"
echo "    cmdctl use <name>      # manual switch"
echo "    cmdctl run -- [args]   # auto-switch launch"
echo ""
echo "Done ✓"
