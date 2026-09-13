#!/usr/bin/env bash
# Native usage analysis for Command Code session logs.
#
# Command Code records a per-turn `usage` block on assistant messages:
#   ~/.commandcode/projects/<project>/<session>.jsonl
#     {"type":"message","timestamp":"...","model":"provider/model",
#      "usage":{"inputTokens":N,"outputTokens":N,
#               "cacheReadTokens":N,"cacheWriteTokens":N,"costUsd":F}, ...}
#
# ccusage does not know this format, so we read it ourselves.

COMMANDCODE_DIR="${COMMANDCODE_DIR:-$HOME/.commandcode}"

# Emit one TSV row per billable turn:
#   date, month, week, session, project, model, input, output, cacheRead, cacheWrite, cost
code_usage_records() {
  local projects_dir="$COMMANDCODE_DIR/projects"
  [[ -d "$projects_dir" ]] || return 0
  find "$projects_dir" -type f -name '*.jsonl' ! -name '*.checkpoints.jsonl' -print0 2>/dev/null \
    | xargs -0 -r jq -r '
        select(has("usage") and (.timestamp != null)) |
        [
          (.timestamp[0:10]),
          (.timestamp[0:7]),
          ((.timestamp[0:19] + "Z") | fromdateiso8601 | strftime("%G-W%V")),
          (input_filename | split("/") | .[-1] | sub("\\.jsonl$"; "")),
          (input_filename | split("/") | .[-2]),
          (.model // "unknown"),
          (.usage.inputTokens // 0),
          (.usage.outputTokens // 0),
          (.usage.cacheReadTokens // 0),
          (.usage.cacheWriteTokens // 0),
          (.usage.costUsd // 0)
        ] | @tsv
      ' 2>/dev/null
}

# Group the records by a view ("daily", "weekly", "monthly", "session").
# Prints all groups, oldest first, as TSV:
#   label, turns, input, output, cache, cost, detail
# `detail` is the model list (or the project, for session view).
code_usage_aggregate() {
  local view="${1:-daily}"
  jq -R -sr --arg view "$view" '
    def num: tonumber? // 0;

    split("\n")
    | map(select(length > 0) | split("\t"))
    | map({
        date: .[0], month: .[1], week: .[2], session: .[3], project: .[4], model: .[5],
        input: (.[6] | num), output: (.[7] | num),
        cache: ((.[8] | num) + (.[9] | num)), cost: (.[10] | num)
      })
    | map(
        if $view == "monthly" then . + {key: .month, label: .month}
        elif $view == "weekly" then . + {key: .week, label: .week}
        elif $view == "session" then . + {key: (.project + "/" + .session), label: (.session[0:8])}
        else . + {key: .date, label: .date}
        end
      )
    | group_by(.key)
    | map({
        label: .[0].label,
        turns: length,
        input: (map(.input) | add),
        output: (map(.output) | add),
        cache: (map(.cache) | add),
        cost: (map(.cost) | add),
        detail: (if $view == "session" then .[0].project else (map(.model) | unique | join(", ")) end)
      })
    | sort_by(.label)
    | .[]
    | [.label, (.turns | tostring), (.input | tostring), (.output | tostring),
       (.cache | tostring), (.cost | tostring), .detail]
    | @tsv
  '
}

# Print a formatted Command Code usage table for a view.
code_usage_report() {
  local view="${1:-daily}" limit="${2:-30}"

  if [[ ! -d "$COMMANDCODE_DIR/projects" ]]; then
    echo "  No Command Code data dir at $COMMANDCODE_DIR/projects"
    return 0
  fi

  local all
  all=$(code_usage_records | code_usage_aggregate "$view")
  if [[ -z "$all" ]]; then
    echo "  No Command Code sessions with usage data found."
    return 0
  fi

  local title
  case "$view" in
    monthly) title="Monthly" ;;
    weekly)  title="Weekly" ;;
    session) title="By session" ;;
    *)       title="Daily" ;;
  esac

  echo "Command Code — $title usage"
  echo ""

  if [[ "$view" == "session" ]]; then
    printf '  %-10s %-7s %-10s %-10s %-10s %-12s %s\n' "SESSION" "TURNS" "INPUT" "OUTPUT" "CACHE" "COST" "PROJECT"
  else
    printf '  %-12s %-7s %-10s %-10s %-10s %-12s %s\n' "${title^^}" "TURNS" "INPUT" "OUTPUT" "CACHE" "COST" "MODELS"
  fi

  # Totals span every group, not just the displayed window.
  local totals
  totals=$(awk -F'\t' '{ turns+=$2; input+=$3; output+=$4; cache+=$5; cost+=$6 }
                       END { printf "%d\t%d\t%d\t%d\t%.6f", turns, input, output, cache, cost }' <<< "$all")

  tail -n "$limit" <<< "$all" | while IFS=$'\t' read -r label turns input output cache cost detail; do
    [[ -z "$label" ]] && continue
    printf '  %-12s %-7s %-10s %-10s %-10s %-12s %s\n' \
      "$label" "$turns" \
      "$(human_tokens "$input")" "$(human_tokens "$output")" "$(human_tokens "$cache")" \
      "$(format_cost "$cost")" "$detail"
  done

  echo ""
  local t_turns t_input t_output t_cache t_cost
  IFS=$'\t' read -r t_turns t_input t_output t_cache t_cost <<< "$totals"
  printf '  TOTAL: %s turns · %s in · %s out · %s cached · %s\n' \
    "$t_turns" "$(human_tokens "$t_input")" "$(human_tokens "$t_output")" \
    "$(human_tokens "$t_cache")" "$(format_cost "$t_cost")"
}

# Machine-readable Command Code usage for a view.
code_usage_json() {
  local view="${1:-daily}"
  code_usage_records | code_usage_aggregate "$view" | jq -R -s '
    split("\n") | map(select(length > 0) | split("\t"))
    | map({
        label: .[0],
        turns: (.[1] | tonumber),
        inputTokens: (.[2] | tonumber),
        outputTokens: (.[3] | tonumber),
        cacheTokens: (.[4] | tonumber),
        costUsd: (.[5] | tonumber),
        detail: .[6]
      })
  '
}

# One-line local Command Code summary (all time + current month).
code_usage_summary() {
  local records all_time month_key month_totals
  records=$(code_usage_records)
  if [[ -z "$records" ]]; then
    echo "  No local Command Code sessions found."
    return 0
  fi

  all_time=$(awk -F'\t' '{ turns++; input+=$7; output+=$8; cache+=$9+$10; cost+=$11 }
                        END { printf "%d\t%d\t%d\t%d\t%.6f", turns, input, output, cache, cost }' <<< "$records")

  month_key=$(date +%Y-%m)
  month_totals=$(awk -F'\t' -v m="$month_key" '$2 == m { turns++; cost+=$11 }
                        END { printf "%d\t%.6f", turns+0, cost+0 }' <<< "$records")

  local t_turns t_input t_output t_cache t_cost m_turns m_cost
  IFS=$'\t' read -r t_turns t_input t_output t_cache t_cost <<< "$all_time"
  IFS=$'\t' read -r m_turns m_cost <<< "$month_totals"

  printf '  All time:  %s turns · %s tokens · %s\n' \
    "$t_turns" "$(human_tokens "$((t_input + t_output))")" "$(format_cost "$t_cost")"
  printf '  This month (%s): %s turns · %s\n' \
    "$month_key" "$m_turns" "$(format_cost "$m_cost")"
}

# Account-wise usage from the Command Code API. This is server-side truth for
# the current billing period and is the only place accounts are visible: local
# session logs never record which account a turn was billed to.
# $1 = "cached" (default) or "fresh".
code_usage_accounts() {
  local mode="${1:-cached}"
  local current_name
  current_name=$(health_get_current)

  printf '  %-20s %-10s %-12s %-11s %-11s %s\n' "ACCOUNT" "STATUS" "PLAN" "TOKENS" "COST" "CREDITS"
  printf '  %-20s %-10s %-12s %-11s %-11s %s\n' "-------" "------" "----" "------" "----" "-------"

  local count=0 healthy=0 total_tokens=0 total_cost=0
  while IFS=$'\t' read -r name probe; do
    [[ -z "$name" ]] && continue
    count=$((count + 1))
    local mark=""
    [[ "$name" == "$current_name" ]] && mark="*"

    local err
    err=$(echo "$probe" | jq -r '.error // empty' 2>/dev/null)
    if [[ -n "$err" ]]; then
      printf '  %-20s %-10s\n' "$mark$name" "$err"
      local key
      key=$(accounts_get_key "$name")
      [[ "$err" == "QUOTA" || "$err" == "AUTH" ]] && health_mark_exhausted "$key"
      continue
    fi

    local status plan tokens cost free purchased
    status=$(echo "$probe" | jq -r '.status // "?"')
    plan=$(echo "$probe" | jq -r '.plan // "?"')
    tokens=$(echo "$probe" | jq -r '.tokens // 0')
    cost=$(echo "$probe" | jq -r '.cost // 0')
    free=$(echo "$probe" | jq -r '.freeCredits // 0')
    purchased=$(echo "$probe" | jq -r '.purchasedCredits // 0')
    healthy=$((healthy + 1))
    total_tokens=$(awk "BEGIN{print $total_tokens + $tokens}")
    total_cost=$(awk "BEGIN{print $total_cost + $cost}")

    printf '  %-20s %-10s %-12s %-11s %-11s %s\n' \
      "$mark$name" "$status" "$plan" \
      "$(human_tokens "$tokens")" "$(format_cost "$cost")" \
      "$(human_tokens "$free") + $(human_tokens "$purchased")"
  done < <(probe_accounts "$mode")

  echo ""
  printf '  TOTAL: %s account(s) · %s healthy · %s tokens · %s (current period)\n' \
    "$count" "$healthy" "$(human_tokens "$total_tokens")" "$(format_cost "$total_cost")"
  [[ -n "$current_name" ]] && echo "  (* = current account)"
  return 0
}

# Machine-readable account-wise usage.
code_usage_accounts_json() {
  local mode="${1:-cached}" current_name
  current_name=$(health_get_current)
  probe_accounts "$mode" | jq -R -s --arg current "$current_name" '
    split("\n") | map(select(length > 0) | split("\t"))
    | map({ name: .[0], probe: (.[1] | fromjson? // {}) })
    | map({
        name: .name,
        current: (.name == $current),
        error: (.probe.error // null),
        status: (.probe.status // null),
        plan: (.probe.plan // null),
        tokens: (.probe.tokens // null),
        costUsd: (.probe.cost // null),
        freeCredits: (.probe.freeCredits // null),
        purchasedCredits: (.probe.purchasedCredits // null)
      })
  '
}

