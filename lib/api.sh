#!/usr/bin/env bash
# Curl-based API client for api.commandcode.ai

# Raw GET with Bearer token. Prints body+httpcode (last line = code).
_api_raw() {
  local path="$1" key="$2"
  curl -s --max-time "$API_TIMEOUT" -w '\n%{http_code}' \
    -H "Authorization: Bearer $key" \
    -H "Accept: application/json" \
    "${API_BASE}${path}" 2>/dev/null
  local rc=$?
  if [[ $rc -ne 0 ]]; then
    printf '\n0\n'
    return 1
  fi
}

# GET a JSON endpoint. On failure prints a single error doc to *stderr*,
# returns non-zero and leaves stdout empty (callers use || fallback safely).
api_get() {
  local path="$1" key="$2"
  local raw http_code body
  raw=$(_api_raw "$path" "$key") || {
    printf '{"error":"NETWORK"}' >&2
    return 1
  }
  http_code="${raw##*$'\n'}"
  body="${raw%$'\n'*}"

  if [[ "$http_code" != "200" ]]; then
    local etype
    etype=$(classify_error "$http_code" "$body")
    printf '{"error":"%s","httpCode":%s}' "$etype" "$http_code" >&2
    return 1
  fi
  printf '%s' "$body"
}

# Classify an HTTP error code + body into AUTH, QUOTA, or NETWORK
classify_error() {
  local code="$1" body="$2"
  case "$code" in
    401|403) echo "AUTH" ;;
    429|402) echo "QUOTA" ;;
    404)     echo "NOTFOUND" ;;
    5*)      echo "NETWORK" ;;
    *)
      echo "$body" | grep -qiE '"code"[: ]*"?(UNAUTHORIZED|quota|limit|exceeded|insufficient)' 2>/dev/null \
        && echo "QUOTA" || echo "UNKNOWN"
      ;;
  esac
}

# Coerce jq output to a number-ish string (first line, non-empty)
_num() {
  echo "$1" 2>/dev/null | jq -r '. // empty' 2>/dev/null | head -1
}

# Full probe. Returns JSON:
#   user, plan, status, freeCredits, purchasedCredits, tokens, cost, period
# or {"error":"..."} on whoami failure.
api_probe() {
  local key="$1"
  local user="?" plan="?" status="?" period="" org_id=""
  local free_cr=0 purchased_cr=0 tokens=0 cost=0

  local whoami whoami_rc
  whoami=$(api_get "/alpha/whoami" "$key" 2>/dev/null)
  whoami_rc=$?
  if (( whoami_rc != 0 )); then
    local err
    err=$(api_get "/alpha/whoami" "$key" 2>&1 | jq -r '.error // "UNKNOWN"' 2>/dev/null)
    printf '{"error":"%s"}' "${err:-UNKNOWN}"
    return 1
  fi
  user=$(echo "$whoami" | jq -r '.user.userName // .userName // "?"' 2>/dev/null | head -1)
  org_id=$(echo "$whoami" | jq -r '.org.id // .orgId // ""' 2>/dev/null | head -1)

  local org_q=""
  [[ -n "$org_id" ]] && org_q="?orgId=$org_id"

  # subscriptions (nullable data) + credits
  local subs credits
  subs=$(api_get "/alpha/billing/subscriptions${org_q}" "$key" 2>/dev/null) || subs='{}'
  credits=$(api_get "/alpha/billing/credits${org_q}" "$key" 2>/dev/null) || credits='{}'

  plan=$(echo "$subs" | jq -r '.data.planName // .data.planId // .planName // .planId // "?"' 2>/dev/null | head -1)
  status=$(echo "$subs" | jq -r '.data.status // .status // "?"' 2>/dev/null | head -1)
  period=$(echo "$subs" | jq -r '.data.currentPeriodStart // .currentPeriodStart // ""' 2>/dev/null | head -1)
  [[ -z "$period" || "$period" == "null" ]] && period=""

  free_cr=$(_num "$(echo "$credits" | jq '.credits.freeCredits // .freeCredits // 0' 2>/dev/null)")
  purchased_cr=$(_num "$(echo "$credits" | jq '.credits.purchasedCredits // .purchasedCredits // 0' 2>/dev/null)")

  # usage summary — default period from the API (this endpoint returns
  # null totals when a `since` filter is supplied, so don't pass one)
  local summary
  summary=$(api_get "/alpha/usage/summary${org_q}" "$key" 2>/dev/null) || summary='{}'
  tokens=$(_num "$(echo "$summary" | jq '.totalTokens // ((.totalTokensIn // 0) + (.totalTokensOut // 0))' 2>/dev/null)")
  cost=$(_num "$(echo "$summary" | jq '.totalCost // .costUsd // .cost // 0' 2>/dev/null)")
  period=$(echo "$summary" | jq -r '.periodBasis // ""' 2>/dev/null | head -1)

  jq -n \
    --arg user "$user" \
    --arg plan "$plan" \
    --arg status "$status" \
    --arg period "$period" \
    --argjson free "${free_cr:-0}" \
    --argjson purchased "${purchased_cr:-0}" \
    --argjson tokens "${tokens:-0}" \
    --argjson cost "${cost:-0}" \
    '{user:$user, plan:$plan, status:$status, period:$period, freeCredits:$free, purchasedCredits:$purchased, tokens:$tokens, cost:$cost}'
}

# Light health check for the watcher. ALWAYS returns 0 (never fails), encoding
# state in the JSON so set -e in callers can't blow up:
#   {"valid":bool, "error":?, "exceeded":bool, "freeCredits", "purchasedCredits",
#    "fiveHourExceeded", "weeklyExceeded", "totalCredits"}
api_health_check() {
  local key="$1"
  local credits
  credits=$(api_get "/alpha/billing/credits" "$key" 2>/dev/null) || {
    local err
    err=$(api_get "/alpha/billing/credits" "$key" 2>&1 | jq -r '.error // "NETWORK"' 2>/dev/null)
    jq -n --arg e "${err:-NETWORK}" '{valid:false, error:$e, exceeded:false}'
    return 0
  }

  local exceeded fh wk free purchased
  exceeded=$(echo "$credits" | jq -r '
    if (.windowLimits.exceeded != null) or
       (.windowLimits.fiveHour.exceeded == true) or
       (.windowLimits.weekly.exceeded == true) then "true"
    else "false" end' 2>/dev/null)
  fh=$(echo "$credits" | jq -r '.windowLimits.fiveHour.exceeded // false' 2>/dev/null)
  wk=$(echo "$credits" | jq -r '.windowLimits.weekly.exceeded // false' 2>/dev/null)
  free=$(_num "$(echo "$credits" | jq '.credits.freeCredits // 0' 2>/dev/null)")
  purchased=$(_num "$(echo "$credits" | jq '.credits.purchasedCredits // 0' 2>/dev/null)")

  jq -n \
    --argjson exceeded "${exceeded:-false}" \
    --argjson fh "${fh:-false}" \
    --argjson wk "${wk:-false}" \
    --argjson f "${free:-0}" \
    --argjson p "${purchased:-0}" \
    '{valid:true, exceeded:$exceeded, fiveHourExceeded:$fh, weeklyExceeded:$wk,
      freeCredits:$f, purchasedCredits:$p, totalCredits:($f + $p)}'
}