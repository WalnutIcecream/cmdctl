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

# Create the env file template if it does not exist yet.
accounts_env_init() {
  if [[ -f "$ENV_FILE" ]]; then
    echo "cmdctl: env file already exists: $ENV_FILE"
    echo "  Add NAME=API_KEY lines, then run: cmdctl accounts import"
    return 0
  fi
  mkdir -p "$(dirname "$ENV_FILE")"
  cat > "$ENV_FILE" <<'EOF'
# cmdctl accounts — one NAME=API_KEY per line.
# Capture a key with: cmd logout && cmd login && jq -r .apiKey ~/.commandcode/auth.json
# Then run: cmdctl accounts import
#
# work=cmd_live_xxxxxxxxxxxxxxxx
# personal=cmd_live_yyyyyyyyyyyyyyyy
EOF
  chmod 600 "$ENV_FILE"
  echo "[cmdctl] Created $ENV_FILE — fill in your keys, then run: cmdctl accounts import"
}

# Parse a dotenv-style file and register every NAME=KEY line as an account.
# Accepts an optional `export ` prefix and an optional CMDCTL_ACCOUNT_ prefix,
# plus single- or double-quoted values. $1 defaults to $ENV_FILE.
# Pass "true" as $2 to stay silent when nothing was imported (auto-load).
accounts_import_env() {
  local file="${1:-$ENV_FILE}" quiet="${2:-false}"
  if [[ ! -f "$file" ]]; then
    echo "cmdctl: env file not found: $file" >&2
    echo "  Create one with: cmdctl accounts env" >&2
    return 1
  fi

  local line name key imported=0 skipped=0
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"

    if [[ -z "$line" || "$line" == \#* ]]; then
      continue
    fi

    line="${line#export }"
    if [[ "$line" != *=* ]]; then
      skipped=$((skipped + 1))
      continue
    fi

    name="${line%%=*}"
    key="${line#*=}"
    name="${name#"${name%%[![:space:]]*}"}"
    name="${name%"${name##*[![:space:]]}"}"
    key="${key#"${key%%[![:space:]]*}"}"
    key="${key%"${key##*[![:space:]]}"}"
    key="${key%\"}"; key="${key#\"}"
    key="${key%\'}"; key="${key#\'}"
    name="${name#CMDCTL_ACCOUNT_}"

    if [[ -z "$name" || -z "$key" || ! "$name" =~ ^[A-Za-z0-9._-]+$ ]]; then
      skipped=$((skipped + 1))
      continue
    fi

    accounts_add "$name" "$key" >/dev/null || { skipped=$((skipped + 1)); continue; }
    echo "[cmdctl] + $name"
    imported=$((imported + 1))
  done < "$file"

  if [[ "$quiet" != "true" || "$imported" -gt 0 ]]; then
    echo "[cmdctl] Imported $imported account(s) from $file"
  fi
  if (( skipped > 0 )); then
    echo "[cmdctl] Skipped $skipped malformed line(s)"
  fi
}

# Show the env file path and a masked preview of its contents.
accounts_env_show() {
  echo "Env file: $ENV_FILE"
  if [[ ! -f "$ENV_FILE" ]]; then
    echo ""
    echo "Not created yet. Run 'cmdctl accounts env' to generate a template."
    return 0
  fi

  echo ""
  local line count=0
  while IFS= read -r line; do
    line="${line#"${line%%[![:space:]]*}"}"
    [[ -z "$line" || "$line" == \#* || "$line" != *=* ]] && continue
    local name="${line%%=*}" key="${line#*=}"
    echo "  ${name}=$(accounts_mask_key "$key")"
    count=$((count + 1))
  done < "$ENV_FILE"
  echo ""
  echo "$count entr$( (( count == 1 )) && echo y || echo ies ) found."
}
