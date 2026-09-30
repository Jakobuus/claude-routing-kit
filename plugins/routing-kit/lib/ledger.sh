#!/bin/bash
# lib/ledger.sh — ledger_append LANE MODEL NAME IN_TOKENS OUT_TOKENS EXIT
# bash 3.2 compatible: no mapfile, no ${x,,}, no associative arrays.
#
# Sourced by callers, not run directly. Depends on kit-common (KIT_HOME).

LEDGER_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
. "$LEDGER_LIB_DIR/../bin/kit-common"

# _ledger_sanitize VALUE — replaces any tab, CR or newline in VALUE with a
# space. A field that smuggled in one of those characters would otherwise
# forge extra rows or columns in the TSV (a newline starts a new row; a tab
# starts a new column).
_ledger_sanitize() {
  printf '%s' "$1" | tr '\t\r\n' '   '
}

# ledger_model_cost MODELS_JSON MODEL INPUT OUTPUT — empty means unknown.
ledger_model_cost() {
  local models_file="$1" model="$2" input_count="$3" output_count="$4"
  [[ $input_count =~ ^[0-9]+$ && $output_count =~ ^[0-9]+$ ]] || return 0
  kit_jq -r --arg model "$model" --argjson input_count "$input_count" --argjson output_count "$output_count" '
    .pricing[$model] as $p |
    if ($p.price_in_per_mtok | type) == "number" and ($p.price_out_per_mtok | type) == "number"
    then (($input_count * $p.price_in_per_mtok + $output_count * $p.price_out_per_mtok) / 1000000 | tostring)
    else "" end
  ' "$models_file" 2>/dev/null | /usr/bin/awk 'NF { printf "%.6f\n", $1 }'
}

# ledger_append LANE MODEL NAME IN_TOKENS OUT_TOKENS EXIT [PROVIDER [COST]] — appends one TSV
# line to $KIT_HOME/ledger.tsv: date lane model name in out exit provider cost. Missing
# trailing fields become "-". Writes the header once.
ledger_append() {
  local lane model name in_tokens out_tokens exit_code provider cost_usd ledger_path date_str
  kit_require_supported
  lane="$(_ledger_sanitize "${1:--}")"
  model="$(_ledger_sanitize "${2:--}")"
  name="$(_ledger_sanitize "${3:--}")"
  in_tokens="$(_ledger_sanitize "${4:--}")"
  out_tokens="$(_ledger_sanitize "${5:--}")"
  exit_code="$(_ledger_sanitize "${6:--}")"
  provider="$(_ledger_sanitize "${7:-}")"
  cost_usd="$(_ledger_sanitize "${8:-}")"

  mkdir -p "$KIT_HOME" || kit_die 2 "could not create $KIT_HOME"
  ledger_path="$KIT_HOME/ledger.tsv"
  if [ ! -f "$ledger_path" ]; then
    printf 'date\tlane\tmodel\tname\tin\tout\texit\tprovider\tcost_usd\n' > "$ledger_path"
  elif [ "$(head -n 1 "$ledger_path")" = $'date\tlane\tmodel\tname\tin\tout\texit' ]; then
    local tmp="$ledger_path.tmp.$$"
    printf 'date\tlane\tmodel\tname\tin\tout\texit\tprovider\tcost_usd\n' > "$tmp"
    tail -n +2 "$ledger_path" >> "$tmp"
    mv "$tmp" "$ledger_path" || kit_die 2 "could not update $ledger_path"
  fi

  date_str="$(date +%Y-%m-%d)"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$date_str" "$lane" "$model" "$name" "$in_tokens" "$out_tokens" "$exit_code" "$provider" "$cost_usd" \
    >> "$ledger_path"
}
