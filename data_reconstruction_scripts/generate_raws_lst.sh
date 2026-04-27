#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
CONFIG_FILE="$SCRIPT_DIR/config.sh"

abspath() {
    local path="$1"
    if [[ "$path" = /* ]]; then
        printf '%s\n' "$path"
    else
        printf '%s\n' "$(cd "$(dirname "$path")" && pwd -P)/$(basename "$path")"
    fi
}

usage() {
    cat <<'EOF'
Usage: generate_raws_lst.sh [--config CONFIG] [--runlist RUNLIST] [--output RAWS]

Resolve the shared raws.lst from the canonical runlist by scanning the configured
raw-data directories with xls.
EOF
}

fatal() {
    echo "Error: $*" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || fatal "Required command not found: $1"
}

RUNLIST_OVERRIDE=""
OUTPUT_OVERRIDE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --config)
            [[ $# -ge 2 ]] || fatal "--config requires a value"
            CONFIG_FILE="$2"
            shift 2
            ;;
        --runlist)
            [[ $# -ge 2 ]] || fatal "--runlist requires a value"
            RUNLIST_OVERRIDE="$2"
            shift 2
            ;;
        --output)
            [[ $# -ge 2 ]] || fatal "--output requires a value"
            OUTPUT_OVERRIDE="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            fatal "Unknown argument: $1"
            ;;
    esac
done

CONFIG_FILE="$(abspath "$CONFIG_FILE")"
[[ -f "$CONFIG_FILE" ]] || fatal "Config file not found: $CONFIG_FILE"

# shellcheck disable=SC1090
. "$CONFIG_FILE"

RUNLIST_PATH="${RUNLIST_OVERRIDE:-$RUNLIST_FILE}"
OUTPUT_PATH="${OUTPUT_OVERRIDE:-$SHARED_RAWS_FILE}"

RUNLIST_PATH="$(abspath "$RUNLIST_PATH")"
OUTPUT_PATH="$(abspath "$OUTPUT_PATH")"

require_command xls
require_command awk

[[ -f "$RUNLIST_PATH" ]] || fatal "Runlist not found: $RUNLIST_PATH"
mkdir -p "$(dirname "$OUTPUT_PATH")"

TMP_OUTPUT="$(mktemp "${TMPDIR:-/tmp}/pathfrac_raws.XXXXXX")"
trap 'rm -f "$TMP_OUTPUT"' EXIT

missing_runs=()
resolved_runs=0

echo "Using runlist: $RUNLIST_PATH"
echo "Writing raws list: $OUTPUT_PATH"
echo

while IFS= read -r raw_run || [[ -n "$raw_run" ]]; do
    run="$(echo "$raw_run" | awk '{gsub(/^[ \t]+|[ \t]+$/, "", $0); print $0}')"
    [[ -n "$run" ]] || continue
    [[ "$run" =~ ^# ]] && continue
    [[ "$run" =~ ^[0-9]+$ ]] || fatal "Invalid run number in $RUNLIST_PATH: $raw_run"

    matches=()
    for raw_dir in "${RAW_SEARCH_DIRS[@]}"; do
        while IFS= read -r candidate; do
            [[ -n "$candidate" ]] || continue
            if [[ "$candidate" = /* ]]; then
                matches+=("$candidate")
            else
                matches+=("$raw_dir/$candidate")
            fi
        done < <(
            xls -D "$raw_dir" 2>/dev/null | grep -E "(^|/)cdr[0-9]+-${run}\.raw$" || true
        )
    done

    if [[ ${#matches[@]} -eq 0 ]]; then
        missing_runs+=("$run")
        echo "Missing raw chunks for run $run" >&2
        continue
    fi

    printf '%s\n' "${matches[@]}" | awk '!seen[$0]++' >> "$TMP_OUTPUT"
    echo "Resolved run $run (${#matches[@]} chunk(s))"
    resolved_runs=$((resolved_runs + 1))
done < "$RUNLIST_PATH"

if [[ ${#missing_runs[@]} -ne 0 ]]; then
    echo >&2
    echo "The following runs could not be resolved:" >&2
    printf '  %s\n' "${missing_runs[@]}" >&2
    exit 1
fi

mv "$TMP_OUTPUT" "$OUTPUT_PATH"
trap - EXIT

echo
echo "Resolved $resolved_runs runs into $(wc -l < "$OUTPUT_PATH" | awk '{print $1}') raw file entries."
echo "Generated: $OUTPUT_PATH"
