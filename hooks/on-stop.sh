#!/usr/bin/env bash
# Stop hook: probes account health at the end of each assistant turn.
# Emits a switch suggestion (continue:false) when the current account is
# really exhausted (windowLimits.exceeded or AUTH/QUOTA), or a token-usage
# warning when approaching the cap heuristic.

set -euo pipefail

HOOK_DIR="$(cd "$(dirname "$0")/.." && pwd)"
LIB_DIR="$HOOK_DIR/lib"

source "$LIB_DIR/common.sh"
source "$LIB_DIR/api.sh"
source "$LIB_DIR/accounts.sh"
source "$LIB_DIR/health.sh"
source "$LIB_DIR/pick.sh"

_init_dirs
_migrate_from_cmdusage

current_name=$(health_get_current)
[[ -z "$current_name" ]] && exit 0

current_key=$(accounts_get_key "$current_name")
[[ -z "$current_key" ]] && exit 0

# Real quota signal: windowLimits.exceeded (executed via credits endpoint)
check=$(api_health_check "$current_key")
valid=$(echo "$check" | jq -r '.valid // "false"')
exceeded=false

if [[ "$valid" == "true" ]]; then
  exceeded=$(echo "$check" | jq -r '.exceeded // "false"')
else
  err=$(echo "$check" | jq -r '.error // "NETWORK"')
  case "$err" in
    QUOTA|AUTH) exceeded=true ;;
  esac
fi

if [[ "$exceeded" == "true" ]]; then
  next=$(pick_best "$current_key" 2>/dev/null) || next=""
  if [[ -n "$next" ]]; then
    cat <<EOF
{"systemMessage":"[cmdctl] $current_name is exhausted. Switch now with: cmdctl next (→ $next)","continue":false,"stopReason":"Account $current_name exhausted window limit. Switch with: cmdctl next"}
EOF
  else
    cat <<EOF
{"systemMessage":"[cmdctl] $current_name is exhausted and no other accounts are available.","continue":false,"stopReason":"All cmdctl accounts exhausted."}
EOF
  fi
  exit 0
fi

# Heuristic warning: near the plan cap
probe=$(health_probe_cached "$current_key" "$current_name" 2>/dev/null) || exit 0
tokens=$(echo "$probe" | jq '.tokens // 0')
if (( tokens > 800000000 )); then
  cat <<EOF
{"systemMessage":"[cmdctl] $current_name: $(human_tokens "$tokens") tokens used this period.","continue":true}
EOF
fi

exit 0