#!/usr/bin/env bash
# State management: exhaustion marks with TTL, probe cache

# Check if an account is marked exhausted (not yet expired)
health_is_exhausted() {
  local key="$1"
  local now=$EPOCHSECONDS
  jq -e --arg k "$key" --argjson now "$now" \
    --argjson ttl "$EXHAUSTED_TTL" \
    '.exhausted // {} | to_entries[] | select(.key == $k and (.value + $ttl) > $now)' \
    "$STATE_FILE" &>/dev/null
}

# Mark an account exhausted
health_mark_exhausted() {
  local key="$1"
  local now=$EPOCHSECONDS
  local tmp
  tmp=$(jq --arg k "$key" --argjson now "$now" \
    '.exhausted = (.exhausted // {}) + {($k): $now}' "$STATE_FILE")
  json_write "$STATE_FILE" "$tmp"
}

# Clear exhaustion for an account (e.g. after period reset detected)
health_clear_exhausted() {
  local key="$1"
  local tmp
  tmp=$(jq --arg k "$key" 'del(.exhausted[$k])' "$STATE_FILE")
  json_write "$STATE_FILE" "$tmp"
}

# Clean up expired exhaustion marks
health_clean_stale() {
  local now=$EPOCHSECONDS
  local tmp
  tmp=$(jq --argjson now "$now" --argjson ttl "$EXHAUSTED_TTL" \
    '.exhausted = ((.exhausted // {}) | to_entries | map(select((.value + $ttl) > $now)) | from_entries)' \
    "$STATE_FILE")
  json_write "$STATE_FILE" "$tmp"
}

# Probe cache: check if we have fresh cached probe data for a key
health_probe_cache_get() {
  local key="$1"
  local now=$EPOCHSECONDS
  jq -c --arg k "$key" --argjson now "$now" --argjson ttl "$PROBE_CACHE_TTL" \
    '.probeCache // {} | to_entries[] | select(.key == $k and (.value.ts + $ttl) > $now) | .value.data' \
    "$STATE_FILE" 2>/dev/null
}

# Store probe result in cache
health_probe_cache_set() {
  local key="$1" data="$2"
  local now=$EPOCHSECONDS
  local tmp
  tmp=$(jq --arg k "$key" --argjson now "$now" --argjson d "$data" \
    '.probeCache = ((.probeCache // {}) + {($k): {ts:$now, data:$d}})' "$STATE_FILE")
  json_write "$STATE_FILE" "$tmp"
}

# Set current account name
health_set_current() {
  local name="$1"
  local tmp
  tmp=$(jq --arg n "$name" '.current = $n' "$STATE_FILE")
  json_write "$STATE_FILE" "$tmp"
}

# Get current account name
health_get_current() {
  jq -r '.current // empty' "$STATE_FILE"
}

# Get cached probe data or probe fresh (respects cache TTL)
health_probe_cached() {
  local key="$1" name="${2:-}"
  local cached
  cached=$(health_probe_cache_get "$key")
  if [[ -n "$cached" && "$cached" != "null" ]]; then
    printf '%s' "$cached"
    return 0
  fi
  local result rc
  result=$(api_probe "$key")
  rc=$?
  if (( rc != 0 )); then
    printf '%s' "$result"
    return 1
  fi
  health_probe_cache_set "$key" "$result"
  printf '%s' "$result"
  return 0
}
