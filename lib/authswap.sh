#!/usr/bin/env bash
# Auth.json atomic swap and restore

# Snapshot current auth.json to backup
auth_backup() {
  if [[ -f "$AUTH_FILE" ]]; then
    cp -a "$AUTH_FILE" "$AUTH_BAK"
  fi
}

# Restore auth.json from backup
auth_restore() {
  if [[ -f "$AUTH_BAK" ]]; then
    mv -f "$AUTH_BAK" "$AUTH_FILE"
  fi
}

# Swap auth.json to use a different account's key
# $1 = account name (looked up from registry)
auth_swap() {
  local name="$1"
  local key
  key=$(accounts_get_key "$name") || {
    echo "cmdctl: account '$name' not found in registry." >&2; return 1
  }
  [[ -z "$key" ]] && {
    echo "cmdctl: account '$name' has no apiKey." >&2; return 1
  }

  # Build new auth.json content
  local new_auth
  new_auth=$(jq -n --arg k "$key" --arg n "$name" '{
    apiKey: $k,
    userName: $n,
    keyName: "cmdctl-managed",
    authenticatedAt: (now | todate)
  }')

  auth_backup
  json_write "$AUTH_FILE" "$new_auth"
  health_set_current "$name"
  chmod 600 "$AUTH_FILE"
}

# Find the real command-code entrypoint
find_real_cli() {
  # Check env override first
  [[ -n "${REAL_CLI:-}" && -f "$REAL_CLI" ]] && { echo "$REAL_CLI"; return; }

  # Try known paths
  local candidates=(
    "$HOME/.npm/lib/node_modules/command-code/dist/index.mjs"
    "$(npm root -g 2>/dev/null)/command-code/dist/index.mjs"
    "/usr/local/lib/node_modules/command-code/dist/index.mjs"
  )
  for c in "${candidates[@]}"; do
    [[ -f "$c" ]] && { echo "$c"; return; }
  done

  # Try finding cmd binary and follow to resolve
  local cmd_bin
  cmd_bin=$(command -v cmd 2>/dev/null) || cmd_bin=$(command -v commandcode 2>/dev/null)
  if [[ -n "$cmd_bin" && -L "$cmd_bin" ]]; then
    local target
    target=$(readlink -f "$cmd_bin")
    [[ -f "$target" ]] && { echo "$target"; return; }
  fi

  return 1
}
