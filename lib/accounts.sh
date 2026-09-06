#!/usr/bin/env bash
# Account registry management

# List all accounts
accounts_list() {
  jq -r '.accounts[]? | "\(.name)\t\(.apiKey[0:12])…\t\(.addedAt // "?")"' "$ACCOUNTS_FILE"
}

# Add account (from current auth.json or manual args)
accounts_add() {
  local name="${1:-}"
  local api_key="${2:-}"
  local username=""

  # If no key provided, capture from current auth.json
  if [[ -z "$api_key" ]]; then
    if [[ ! -f "$AUTH_FILE" ]]; then
      echo "cmdctl: $AUTH_FILE not found. Run 'cmd login' first." >&2; return 1
    fi
    api_key=$(jq -r '.apiKey // empty' "$AUTH_FILE") || {
      echo "cmdctl: $AUTH_FILE has no apiKey field." >&2; return 1
    }
    [[ -z "$api_key" ]] && {
      echo "cmdctl: apiKey is empty in $AUTH_FILE." >&2; return 1
    }
    username=$(jq -r '.userName // "?"' "$AUTH_FILE")
    name="${name:-$username}"
  fi

  if [[ -z "$name" ]]; then
    echo "cmdctl: account name required." >&2; return 1
  fi

  local existing
  existing=$(jq --arg n "$name" '.accounts | map(select(.name == $n)) | length' "$ACCOUNTS_FILE")
  local entry
  entry=$(jq -n --arg n "$name" --arg k "$api_key" '{name:$n, apiKey:$k, addedAt:(now | todate)}')

  if [[ "$existing" -gt 0 ]]; then
    local tmp
    tmp=$(jq --arg n "$name" --argjson e "$entry" '(.accounts |= map(if .name == $n then $e else . end))' "$ACCOUNTS_FILE")
    json_write "$ACCOUNTS_FILE" "$tmp"
    echo "[cmdctl] Updated account: $name"
  else
    local tmp
    tmp=$(jq --argjson e "$entry" '.accounts += [$e]' "$ACCOUNTS_FILE")
    json_write "$ACCOUNTS_FILE" "$tmp"
    echo "[cmdctl] Added account: $name (user: ${username:-?})"
  fi
}

# Remove account by name
accounts_rm() {
  local name="$1"
  [[ -z "$name" ]] && { echo "cmdctl: account name required." >&2; return 1; }
  local count
  count=$(jq --arg n "$name" '.accounts | map(select(.name == $n)) | length' "$ACCOUNTS_FILE")
  if [[ "$count" -eq 0 ]]; then
    echo "cmdctl: account '$name' not found." >&2; return 1
  fi
  local tmp
  tmp=$(jq --arg n "$name" '.accounts |= map(select(.name != $n))' "$ACCOUNTS_FILE")
  json_write "$ACCOUNTS_FILE" "$tmp"
  echo "[cmdctl] Removed account: $name"
}

# Rename account
accounts_rename() {
  local old="$1" new="$2"
  [[ -z "$old" || -z "$new" ]] && { echo "cmdctl: usage: cmdctl accounts rename OLD NEW" >&2; return 1; }
  local count
  count=$(jq --arg o "$old" '.accounts | map(select(.name == $o)) | length' "$ACCOUNTS_FILE")
  if [[ "$count" -eq 0 ]]; then
    echo "cmdctl: account '$old' not found." >&2; return 1
  fi
  local conflict
  conflict=$(jq --arg n "$new" '.accounts | map(select(.name == $n)) | length' "$ACCOUNTS_FILE")
  if [[ "$conflict" -gt 0 ]]; then
    echo "cmdctl: account '$new' already exists." >&2; return 1
  fi
  local tmp
  tmp=$(jq --arg o "$old" --arg n "$new" '.accounts |= map(if .name == $o then (.name = $n) else . end)' "$ACCOUNTS_FILE")
  json_write "$ACCOUNTS_FILE" "$tmp"
  echo "[cmdctl] Renamed: $old → $new"
}

# Show account details (by name, or current)
accounts_show() {
  local name="${1:-}"
  if [[ -n "$name" ]]; then
    jq --arg n "$name" '.accounts[] | select(.name == $n)' "$ACCOUNTS_FILE"
  else
    local cur
    cur=$(jq -r '.current // empty' "$STATE_FILE")
    if [[ -n "$cur" ]]; then
      jq --arg n "$cur" '.accounts[] | select(.name == $n)' "$ACCOUNTS_FILE"
    else
      echo "cmdctl: no current account set. Use 'cmdctl use <name>'." >&2; return 1
    fi
  fi
}

# Get API key for an account name
accounts_get_key() {
  local name="$1"
  jq -r --arg n "$name" '.accounts[] | select(.name == $n) | .apiKey // empty' "$ACCOUNTS_FILE"
}

# List all names
accounts_names() {
  jq -r '.accounts[].name' "$ACCOUNTS_FILE"
}

# Count
accounts_count() {
  jq '.accounts | length' "$ACCOUNTS_FILE"
}

# Mask a key for display
accounts_mask_key() {
  local key="$1"
  if [[ ${#key} -gt 12 ]]; then
    printf '%s…%s' "${key:0:8}" "${key: -4}"
  else
    printf '…'
  fi
}
