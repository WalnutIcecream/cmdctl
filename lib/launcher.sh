#!/usr/bin/env bash
# Managed launcher: pre-flight check, watcher, quota-fail rotate, relaunch

LAUNCHER_ROTATED_KEYS=""
LAUNCHER_MAX_CYCLES=1
_LAUNCHER_QUOTA_FLAG="$CMDCTL_DIR/.watcher-kill"

# Append --continue --yolo to args if not already present (deduped)
_launcher_append_resume_flags() {
  local args=() has_cont=false has_yolo=false
  for a in "$@"; do
    case "$a" in
      --continue|-c) has_cont=true ;;
      --yolo)        has_yolo=true ;;
    esac
    args+=("$a")
  done
  $has_cont || args+=("--continue")
  $has_yolo  || args+=("--yolo")
  echo "${args[@]}"
}

# Background watcher: polls every POLL_INTERVAL, kills child when the account
# hits a hard quota signal (windowLimits exceeded, QUOTA/AUTH error) or an
# optional TOKEN_CAP is reached.
_launcher_watcher() {
  local key="$1" child_pid="$2"
  while kill -0 "$child_pid" 2>/dev/null; do
    sleep "$POLL_INTERVAL" || break
    kill -0 "$child_pid" 2>/dev/null || break

    local check
    check=$(api_health_check "$key")
    local valid
    valid=$(echo "$check" | jq -r '.valid // "false"')
    if [[ "$valid" != "true" ]]; then
      local err
      err=$(echo "$check" | jq -r '.error // "NETWORK"')
      case "$err" in
        QUOTA|AUTH)
          touch "$_LAUNCHER_QUOTA_FLAG"
          kill "$child_pid" 2>/dev/null
          break
          ;;
        *) continue ;;
      esac
    fi

    local exceeded
    exceeded=$(echo "$check" | jq -r '.exceeded // "false"')
    if [[ "$exceeded" == "true" ]]; then
      touch "$_LAUNCHER_QUOTA_FLAG"
      kill "$child_pid" 2>/dev/null
      break
    fi

    # Optional proactive rotation before the hard cap
    if (( ${TOKEN_CAP:-0} > 0 )); then
      local tokens
      tokens=$(api_get "/alpha/usage/summary" "$key" 2>/dev/null \
        | jq '.totalTokens // 0' 2>/dev/null | head -1)
      if [[ -n "$tokens" ]] && (( tokens >= TOKEN_CAP )); then
        touch "$_LAUNCHER_QUOTA_FLAG"
        kill "$child_pid" 2>/dev/null
        break
      fi
    fi
  done
}

# Classify a process exit as quota-related
_launcher_is_quota_exit() {
  local exit_code="$1"
  # Watcher flagged it
  [[ -f "$_LAUNCHER_QUOTA_FLAG" ]] && { rm -f "$_LAUNCHER_QUOTA_FLAG"; return 0; }
  # Exit code 402/429 mapped, or signal 9 (watcher SIGKILL after SIGTERM)
  [[ "$exit_code" -eq 42 || "$exit_code" -eq 34 ]] && return 0
  return 1
}

# The main run loop
launcher_run() {
  local args=("$@")
  rm -f "$_LAUNCHER_QUOTA_FLAG"

  local real_cli
  real_cli=$(find_real_cli) || {
    echo "cmdctl: command-code CLI not found. Install with: npm i -g command-code" >&2
    return 1
  }

  # Pre-flight: check current account health
  local current_name current_key
  current_name=$(health_get_current)
  if [[ -n "$current_name" ]]; then
    current_key=$(accounts_get_key "$current_name")
    if [[ -n "$current_key" ]]; then
      if health_is_exhausted "$current_key" 2>/dev/null; then
        echo "[cmdctl] Current account ($current_name) exhausted — selecting best available..." >&2
        local next_name
        next_name=$(pick_best "$current_key")
        if [[ -n "$next_name" ]]; then
          auth_swap "$next_name"
          echo "[cmdctl] Switched to $next_name for this run" >&2
        else
          echo "[cmdctl] All accounts exhausted." >&2
          return 1
        fi
      fi
    fi
  else
    # No current account — pick best
    local next_name
    next_name=$(pick_best)
    if [[ -n "$next_name" ]]; then
      auth_swap "$next_name"
      echo "[cmdctl] Starting on $next_name" >&2
    fi
  fi

  # Run loop with rotation on quota failure
  local cycle=0
  LAUNCHER_ROTATED_KEYS=""

  while (( cycle <= LAUNCHER_MAX_CYCLES )); do
    # Get current key
    current_name=$(health_get_current)
    current_key=$(accounts_get_key "$current_name")

    if (( cycle > 0 )); then
      # Rotate: pick best excluding all previously used keys
      local exclude_list="${LAUNCHER_ROTATED_KEYS%,}"
      local next_name
      next_name=$(pick_best_excluding "$exclude_list") || {
        echo "[cmdctl] No more accounts available after $cycle rotation(s)." >&2
        return 1
      }
      auth_swap "$next_name"
      current_name="$next_name"
      current_key=$(accounts_get_key "$next_name")
      LAUNCHER_ROTATED_KEYS="${LAUNCHER_ROTATED_KEYS}${current_key},"
      echo "[cmdctl] ── Rotated to $next_name (cycle $cycle/$LAUNCHER_MAX_CYCLES) ──" >&2

      # Append resume flags for relaunched interactive sessions
      args=($(_launcher_append_resume_flags "${args[@]}"))
    fi

    # Mark this key as used for rotation
    if [[ -n "$current_key" ]]; then
      LAUNCHER_ROTATED_KEYS="${LAUNCHER_ROTATED_KEYS}${current_key},"
    fi

    # Start watcher watching the real child PID
    rm -f "$_LAUNCHER_QUOTA_FLAG"

    # Launch real CLI in background so the watcher can target the exact PID.
    # TTY is inherited; in non-interactive bash all procs share the pgroup, so
    # Ctrl-C (SIGINT) and Ctrl-Z still reach the whole pipeline.
    set +e
    node "$real_cli" "${args[@]}" &
    local child_pid=$!
    _launcher_watcher "$current_key" "$child_pid" &
    local watcher_pid=$!

    # Wait for child to finish (returns its real exit code)
    wait "$child_pid"
    local exit_code=$?
    set -e

    # Stop watcher. `wait` returns the killed job's (nonzero) status — ignore it.
    set +e
    kill "$watcher_pid" 2>/dev/null
    wait "$watcher_pid" 2>/dev/null || true
    set -e

    # Check if we should rotate
    if _launcher_is_quota_exit "$exit_code"; then
      if [[ -n "$current_key" ]]; then
        health_mark_exhausted "$current_key"
        echo "[cmdctl] $current_name hit quota limit — rotating..." >&2
      fi
      cycle=$((cycle + 1))
      continue
    fi

    # Normal exit
    return "$exit_code"
  done

  echo "[cmdctl] Exhausted all rotation cycles." >&2
  return 1
}

# Watcher subcommand: just run the watcher standalone (for testing)
launcher_watcher_test() {
  local name="$1" pid="$2"
  local key
  key=$(accounts_get_key "$name")
  echo "[cmdctl-test] Watching $name (key: $(accounts_mask_key "$key")) for PID $pid" >&2
  _launcher_watcher "$key" "$pid"
  echo "[cmdctl-test] Watcher exit" >&2
}
