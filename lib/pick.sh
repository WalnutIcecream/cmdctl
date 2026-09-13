#!/usr/bin/env bash
# Account selection: rank non-exhausted accounts (parallel probes)

# Probe accounts in parallel; writes results to per-pid temp files and
# returns nothing else. Callers parse the files afterward.
_pick_probe_all() {
  local tmpdir="$PICK_TMPDIR"
  local job_pids=()
  local idx=0
  local name key
  while IFS=$'\t' read -r name key; do
    [[ -z "$name" ]] && continue
    (
      health_probe_cached "$key" "$name" >"$tmpdir/$idx" 2>/dev/null
    ) &
    job_pids+=("$!")
    idx=$((idx + 1))
  done
  for pid in "${job_pids[@]}"; do
    wait "$pid" 2>/dev/null
  done
}

# Read probe output file; prints JSON or nothing
_pick_read_probe() {
  [[ -f "$1" ]] && cat "$1" 2>/dev/null
}

# Score a probe JSON: active >> anything, less tokens used = better
_pick_score() {
  local probe="$1"
  local status tokens
  status=$(echo "$probe" | jq -r '.status // "?"' 2>/dev/null)
  tokens=$(echo "$probe" | jq '.tokens // 0' 2>/dev/null)
  case "$status" in
    active|trialing)  echo $(( 2000000000 - tokens )) ;;
    past_due|incomplete) echo $(( 1000000000 - tokens )) ;;
    *)                echo $(( 500000000 - tokens )) ;;
  esac
}

# Pick the best available account (name). Returns nothing if all exhausted.
pick_best() {
  local exclude_key="${1:-}"
  health_clean_stale

  local candidates
  candidates=$(jq -r --arg ek "$exclude_key" \
    '.accounts[] | select(.apiKey != $ek) | "\(.name)\t\(.apiKey)"' "$ACCOUNTS_FILE")
  [[ -z "$candidates" ]] && return

  local tmpdir
  tmpdir=$(mktemp -d)
  PICK_TMPDIR="$tmpdir"
  _pick_probe_all <<< "$candidates"
  unset PICK_TMPDIR

  local best=""
  local idx=0
  local max_score=-100000000
  while IFS=$'\t' read -r name key; do
    [[ -z "$name" ]] && continue
    local probe
    probe=$(_pick_read_probe "$tmpdir/$idx")
    idx=$((idx + 1))
    [[ -z "$probe" ]] && continue

    # Skip exhausted (probe error path already marked them)
    local err
    err=$(echo "$probe" | jq -r '.error // empty' 2>/dev/null)
    [[ -n "$err" ]] && continue

    local score
    score=$(_pick_score "$probe")
    if (( score > max_score )); then
      best="$name"
      max_score=$score
    fi
  done <<< "$candidates"
  [[ -n "$best" ]] && printf '%s' "$best"
}

# Probe every registered account in parallel. Prints name<TAB>json lines.
# Set $1 to "fresh" to bypass the probe cache; otherwise cached results are used.
probe_accounts() {
  local mode="${1:-cached}"
  local tmpdir pids=() names=()
  tmpdir=$(mktemp -d)
  local idx=0 name key
  while IFS=$'\t' read -r name key; do
    [[ -z "$name" ]] && continue
    (
      if [[ "$mode" == "fresh" ]]; then
        api_probe "$key" >"$tmpdir/$idx" 2>/dev/null || true
      else
        health_probe_cached "$key" "$name" >"$tmpdir/$idx" 2>/dev/null || true
      fi
    ) &
    pids+=("$!")
    names+=("$name")
    idx=$((idx + 1))
  done < <(jq -r '.accounts[] | "\(.name)\t\(.apiKey)"' "$ACCOUNTS_FILE")

  local pid
  for pid in "${pids[@]}"; do
    wait "$pid" 2>/dev/null || true
  done

  local i=0
  for name in "${names[@]}"; do
    printf '%s\t%s\n' "$name" "$(cat "$tmpdir/$i" 2>/dev/null)"
    i=$((i + 1))
  done
  rm -rf "$tmpdir"
}

# Pick best excluding multiple keys (rotation fallback)
pick_best_excluding() {
  local exclude_keys="$1"
  health_clean_stale

  local candidates
  candidates=$(jq -r --arg ek "$exclude_keys" \
    '.accounts[] | select(.apiKey as $k | ($ek | split(",") | index($k)) | not) | "\(.name)\t\(.apiKey)"' \
    "$ACCOUNTS_FILE")
  [[ -z "$candidates" ]] && return

  local tmpdir
  tmpdir=$(mktemp -d)
  PICK_TMPDIR="$tmpdir"
  _pick_probe_all <<< "$candidates"
  unset PICK_TMPDIR

  local best=""
  local idx=0
  while IFS=$'\t' read -r name key; do
    [[ -z "$name" ]] && continue
    local probe
    probe=$(_pick_read_probe "$tmpdir/$idx")
    idx=$((idx + 1))
    [[ -z "$probe" ]] && continue

    local err
    err=$(echo "$probe" | jq -r '.error // empty' 2>/dev/null)
    [[ -n "$err" ]] && continue

    local score max_score
    score=$(_pick_score "$probe")
    max_score=-100000000
    if (( score > max_score )); then
      best="$name"
      max_score=$score
    fi
  done <<< "$candidates"
  [[ -n "$best" ]] && printf '%s' "$best"
}