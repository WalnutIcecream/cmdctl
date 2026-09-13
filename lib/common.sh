#!/usr/bin/env bash
# Shared constants and JSON helpers

CMDCTL_DIR="${CMDCTL_DIR:-$HOME/.config/cmdctl}"
ACCOUNTS_FILE="$CMDCTL_DIR/accounts.json"
STATE_FILE="$CMDCTL_DIR/state.json"
ENV_FILE="${CMDCTL_ENV_FILE:-$CMDCTL_DIR/accounts.env}"
AUTH_FILE="${AUTH_FILE:-$HOME/.commandcode/auth.json}"
AUTH_BAK="${AUTH_FILE}.cmdctl-bak"

# Coding harnesses and report views understood by ccusage.
CCUSAGE_SOURCES="claude codex opencode amp droid codebuff hermes pi goose openclaw kilo kimi qwen copilot gemini antigravity grok zcode"
CCUSAGE_VIEWS="daily weekly monthly session"

# Harnesses cmdctl reads natively from local session logs (ccusage has no source
# for these). Command Code is the one that ships with this tool.
NATIVE_SOURCES="commandcode command-code command_code cmd cc"
NATIVE_SOURCE_LABEL="commandcode"

# Defaults for `cmdctl usage` when no harness/view is given on the command line.
# "account" is the headline view: per-account totals from the Command Code API.
CMDCTL_DEFAULT_SOURCE="${CMDCTL_DEFAULT_SOURCE:-}"
CMDCTL_DEFAULT_VIEW="${CMDCTL_DEFAULT_VIEW:-account}"

API_BASE="https://api.commandcode.ai"
API_TIMEOUT=${API_TIMEOUT:-20}
EXHAUSTED_TTL=${EXHAUSTED_TTL:-3600}
PROBE_CACHE_TTL=${PROBE_CACHE_TTL:-300}
POLL_INTERVAL=${POLL_INTERVAL:-15}

_init_dirs() {
  mkdir -p "$CMDCTL_DIR"
  [[ -f "$ACCOUNTS_FILE" ]] || printf '{"accounts":[]}\n' > "$ACCOUNTS_FILE"
  [[ -f "$STATE_FILE" ]] || printf '{"current":null}\n' > "$STATE_FILE"
}

_migrate_from_cmdusage() {
  local old="$HOME/.config/cmdusage/accounts.json"
  local empty_empty
  empty_empty=$(jq '.accounts | length == 0' "$ACCOUNTS_FILE" 2>/dev/null || echo true)
  if [[ -f "$old" && "$empty_empty" == "true" ]]; then
    json_write "$ACCOUNTS_FILE" "$(jq '.' "$old")"
    echo "[cmdctl] Migrated accounts from cmdusage" >&2
  fi
}

# Auto-load accounts from the env file when the registry is still empty.
_import_env_if_empty() {
  [[ -f "$ENV_FILE" ]] || return 0
  local count
  count=$(jq '.accounts | length' "$ACCOUNTS_FILE" 2>/dev/null || echo 0)
  [[ "${count:-0}" -gt 0 ]] && return 0
  accounts_import_env "$ENV_FILE" true >&2
}

# True when the argument names a ccusage harness (claude, codex, ...).
is_ccusage_source() {
  local candidate="$1" source
  for source in $CCUSAGE_SOURCES; do
    [[ "$candidate" == "$source" ]] && return 0
  done
  return 1
}

# True when the argument names a harness cmdctl reads natively (commandcode, ...).
is_native_source() {
  local candidate="$1" source
  for source in $NATIVE_SOURCES; do
    [[ "$candidate" == "$source" ]] && return 0
  done
  return 1
}

# True when the argument names a ccusage report view (daily, weekly, ...).
is_ccusage_view() {
  local candidate="$1" view
  for view in $CCUSAGE_VIEWS; do
    [[ "$candidate" == "$view" ]] && return 0
  done
  return 1
}

# Atomic JSON write
json_write() {
  local path="$1" content="$2"
  mkdir -p "$(dirname "$path")"
  local tmp="${path}.tmp.$$"
  printf '%s\n' "$content" > "$tmp"
  mv -f "$tmp" "$path"
}

# Read JSON file (returns raw JSON on stdout)
json_read() {
  jq '.' "$1" 2>/dev/null || printf 'null'
}

human_tokens() {
  local n=$1
  [[ "$n" == "null" || -z "$n" ]] && { printf '—'; return; }
  awk "BEGIN{n=$n;
    if(n>=1e9) printf \"%.1fB\",n/1e9;
    else if(n>=1e6) printf \"%.1fM\",n/1e6;
    else if(n>=1e3) printf \"%.1fk\",n/1e3;
    else printf \"%d\",n}"
}

format_cost() {
  local n="${1:-0}"
  [[ "$n" == "null" || -z "$n" ]] && { printf '$0.00'; return; }
  awk "BEGIN{printf \"\$%.2f\", $n}"
}

# Detect whether ccusage is runnable (native binary, npx, or bunx).
has_ccusage() {
  command -v ccusage  >/dev/null 2>&1 ||
  command -v npx      >/dev/null 2>&1 ||
  command -v bunx     >/dev/null 2>&1
}

# Run ccusage through whichever runner is available. Prints output, returns
# non-zero if no runner exists or ccusage itself fails.
ccusage_run() {
  if command -v ccusage >/dev/null 2>&1; then
    ccusage "$@"
  elif command -v npx >/dev/null 2>&1; then
    npx --yes ccusage@latest "$@"
  elif command -v bunx >/dev/null 2>&1; then
    bunx --yes ccusage@latest "$@"
  else
    return 127
  fi
}

# Draw a simple 0..20 char ASCII usage bar. $1 = current, $2 = cap (0 => no cap).
usage_bar() {
  local cur="${1:-0}" cap="${2:-0}"
  if [[ "$cap" == "0" || "$cap" == "null" || -z "$cap" ]]; then
    printf '%s' "────────────────────"
    return
  fi
  awk -v cur="$cur" -v cap="$cap" 'BEGIN{
    filled = int((cur/cap)*20);
    if (filled > 20) filled = 20;
    if (filled < 0) filled = 0;
    for (i=0;i<filled;i++) printf "█";
    for (i=filled;i<20;i++) printf "░";
  }'
}

color() {
  case "$1" in
    bold)   printf '\033[1m%s\033[0m' "$2" ;;
    dim)    printf '\033[2m%s\033[0m' "$2" ;;
    red)    printf '\033[31m%s\033[0m' "$2" ;;
    green)  printf '\033[32m%s\033[0m' "$2" ;;
    yellow) printf '\033[33m%s\033[0m' "$2" ;;
    *)      printf '%s' "$2" ;;
  esac
}

_color_enabled() {
  [[ -t 1 && -z "${NO_COLOR:-}" ]]
}
