#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(cd "$SCRIPT_DIR/" && pwd)"
ANALYSIS_DIR="$(cd "$BASE_DIR/" && pwd)"
BATCH_UTILS_DIR="$HOME/BatchJobUtils/scripts"

TEMPLATE_OPT="$BASE_DIR/config/t.opt"
ENV_SCRIPT="$BASE_DIR/config/env.sh"
DATALIST_FILE="$BASE_DIR/config/raws.lst"
FRACTIONS_FILE="$BASE_DIR/config/pathfracs.lst"
OUTPUT_BASE="$HOME/myeos/BC/output/htcondor_scan"
WORK_BASE="/afs/cern.ch/work/s/sprazsky"
HTC_SUB_CORAL="$BATCH_UTILS_DIR/htc_sub_coral"
TAG="$(date +%Y%m%d-%H%M%S)"
MODE="settings-only"
MAXJOBS=500
PER_FRACTION_MAXJOBS=""
UNUSED_MAXJOBS=0
COMPACT_CORAL_LOG="compactCoralLog.py"

declare -a PATHFRAC_VALUES=()
declare -a FRACTION_TAGS=()

print_usage() {
    cat <<EOF
Usage:
  $(basename "$0") [options]

helper for ParticlePathFrac CORAL reconstruction.
It can:
  - write option/settings files only,
  - prepare HTCondor DAGs without submission,
  - submit all selected emission points on CERN HTCondor,
  - submit at most one emission point per invocation.

Default mode: --settings-only
Backend contract: one ParticlePathFrac value produces one option file, one
settings file, and one htc_sub_coral invocation.

Options:
  --datalist FILE          Raw-data list file. Default: $DATALIST_FILE
  --fractions CSV          ParticlePathFrac values, e.g. 0.1,0.3,0.5
  --fractions-file FILE    File with one ParticlePathFrac value per line.
                           Default: $FRACTIONS_FILE
  --output-base DIR        Base output directory. Default: $OUTPUT_BASE
  --work-base DIR          Base directory for HTCondor work dirs.
                           Default: $WORK_BASE
  --template-opt FILE      CORAL option template. Default: $TEMPLATE_OPT
  --env-script FILE        CORAL environment script. Default: $ENV_SCRIPT
  --tag LABEL              Label. Default: current timestamp
  --settings-only          Only write option/settings/manifest/work-dir files
                           (default)
  --prepare                Run htc_sub_coral without submission
  --submit                 Run htc_sub_coral and submit to HTCondor
  --submit-by-emission-point
                           Submit at most one emission point per invocation,
                           reusing existing prepared/submitted work dirs.
  --maxjobs N              Total concurrent jobs across all selected
                           emission points when used with --submit, or the
                           full per-emission-point cap for
                           --submit-by-emission-point.
                           Default: $MAXJOBS
  --htc-sub-coral FILE     Override htc_sub_coral path
  --help                   Show this help

Examples:
  $(basename "$0") --datalist "$BASE_DIR/config/raws.lst" \\
    --output-base /eos/user/s/sprazsky/bc_thesis/output_pathfrac \\
    --tag transv2022W08

  $(basename "$0") --settings-only \\
    --datalist "$BASE_DIR/config/raws.lst" \\
    --fractions 0.1,0.5,0.9 \\
    --output-base /eos/user/s/sprazsky/bc_thesis/output_pathfrac \\
    --tag settings_preview

  $(basename "$0") --submit --maxjobs 200 \\
    --datalist my_raws.lst \\
    --fractions 0.1,0.3,0.5,0.7,0.9 \\
    --output-base /eos/user/s/sprazsky/bc_thesis/output_pathfrac \\
    --tag production_scan

  $(basename "$0") --submit-by-emission-point --maxjobs 1200 \\
    --fractions-file config/pathfracs.lst \\
    --tag 20260421-200100
EOF
}

abs_path() {
    local path="$1"

    if [[ -d "$path" ]]; then
        (
            cd "$path"
            pwd
        )
        return
    fi

    local dir
    local base
    dir="$(cd "$(dirname "$path")" && pwd)"
    base="$(basename "$path")"
    printf '%s/%s\n' "$dir" "$base"
}

parse_fraction_file() {
    local file="$1"
    local line=""

    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%%#*}"
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        [[ -z "$line" ]] && continue
        PATHFRAC_VALUES+=("$line")
    done < "$file"
}

parse_fraction_csv() {
    local csv="$1"
    local token=""

    csv="${csv//,/ }"
    for token in $csv; do
        [[ -z "$token" ]] && continue
        PATHFRAC_VALUES+=("$token")
    done
}

validate_fraction() {
    local value="$1"
    awk -v v="$value" '
        BEGIN {
            if (v !~ /^([0-9]+([.][0-9]*)?|[.][0-9]+)$/) exit 1;
            if (v < 0 || v > 1) exit 2;
        }'
}

validate_positive_integer() {
    local value="$1"
    [[ "$value" =~ ^[1-9][0-9]*$ ]]
}

fraction_tag() {
    local pathfrac="$1"
    printf '%s-%s\n' "$TAG" "$pathfrac"
}

work_dir_state() {
    local work_dir="$1"
    local first_entry=""

    if [[ ! -d "$work_dir" ]]; then
        echo "missing"
        return
    fi

    first_entry="$(find "$work_dir" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null || true)"
    if [[ -z "$first_entry" ]]; then
        echo "empty"
        return
    fi

    if [[ -f "$work_dir/condor.dag" ]]; then
        if [[ -f "$work_dir/condor.dag.dagman.log" || -f "$work_dir/condor.dag.condor.sub" || -f "$work_dir/condor.dag.nodes.log" || -f "$work_dir/condor.dag.metrics" ]]; then
            echo "submitted"
        else
            echo "prepared"
        fi
        return
    fi

    echo "partial"
}

count_particle_pathfrac_lines() {
    local template_file="$1"
    awk '
        $1 == "RICHONE" && $2 == "ParticlePathFrac" { count++ }
        END { print count + 0 }
    ' "$template_file"
}

resolve_compact_coral_log() {
    local htc_sub_coral="$1"
    local candidate_dir=""
    local candidate=""

    candidate_dir="$(cd "$(dirname "$htc_sub_coral")" && pwd)"
    candidate="$candidate_dir/compactCoralLog.py"
    if [[ -f "$candidate" ]]; then
        printf '%s\n' "$candidate"
        return
    fi

    candidate="$BATCH_UTILS_DIR/compactCoralLog.py"
    if [[ -f "$candidate" ]]; then
        printf '%s\n' "$candidate"
        return
    fi

    printf '%s\n' "compactCoralLog.py"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --datalist)
            DATALIST_FILE="$2"
            shift 2
            ;;
        --fractions)
            parse_fraction_csv "$2"
            shift 2
            ;;
        --fractions-file)
            FRACTIONS_FILE="$2"
            shift 2
            ;;
        --output-base)
            OUTPUT_BASE="$2"
            shift 2
            ;;
        --work-base)
            WORK_BASE="$2"
            shift 2
            ;;
        --template-opt)
            TEMPLATE_OPT="$2"
            shift 2
            ;;
        --env-script)
            ENV_SCRIPT="$2"
            shift 2
            ;;
        --tag)
            TAG="$2"
            shift 2
            ;;
        --settings-only)
            MODE="settings-only"
            shift
            ;;
        --prepare)
            MODE="prepare"
            shift
            ;;
        --submit)
            MODE="submit"
            shift
            ;;
        --submit-by-emission-point)
            MODE="submit-by-emission-point"
            shift
            ;;
        --maxjobs)
            MAXJOBS="$2"
            shift 2
            ;;
        --htc-sub-coral)
            HTC_SUB_CORAL="$2"
            shift 2
            ;;
        --help)
            print_usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            print_usage >&2
            exit 1
            ;;
    esac
done

if [[ ! -f "$TEMPLATE_OPT" ]]; then
    echo "Error: template option file '$TEMPLATE_OPT' not found." >&2
    exit 1
fi

if [[ ! -f "$ENV_SCRIPT" ]]; then
    echo "Error: environment script '$ENV_SCRIPT' not found." >&2
    exit 1
fi

if [[ ! -f "$DATALIST_FILE" ]]; then
    echo "Error: data list file '$DATALIST_FILE' not found." >&2
    exit 1
fi

if [[ ${#PATHFRAC_VALUES[@]} -eq 0 ]]; then
    if [[ ! -f "$FRACTIONS_FILE" ]]; then
        echo "Error: no fractions specified and default fractions file '$FRACTIONS_FILE' was not found." >&2
        exit 1
    fi
    parse_fraction_file "$FRACTIONS_FILE"
fi

if [[ ${#PATHFRAC_VALUES[@]} -eq 0 ]]; then
    echo "Error: no ParticlePathFrac values were provided." >&2
    exit 1
fi

if ! validate_positive_integer "$MAXJOBS"; then
    echo "Error: --maxjobs expects a positive integer, got '$MAXJOBS'." >&2
    exit 1
fi

if [[ "$MODE" != "settings-only" && ! -x "$HTC_SUB_CORAL" ]]; then
    echo "Error: htc_sub_coral '$HTC_SUB_CORAL' is not executable." >&2
    exit 1
fi

mkdir -p "$BASE_DIR/opt_files" "$BASE_DIR/settings_files" "$OUTPUT_BASE"

TEMPLATE_OPT="$(abs_path "$TEMPLATE_OPT")"
ENV_SCRIPT="$(abs_path "$ENV_SCRIPT")"
DATALIST_FILE="$(abs_path "$DATALIST_FILE")"
OUTPUT_BASE="$(abs_path "$OUTPUT_BASE")"
WORK_BASE="$(abs_path "$WORK_BASE")"
if [[ -f "$FRACTIONS_FILE" ]]; then
    FRACTIONS_FILE="$(abs_path "$FRACTIONS_FILE")"
fi
if [[ -e "$HTC_SUB_CORAL" ]]; then
    HTC_SUB_CORAL="$(abs_path "$HTC_SUB_CORAL")"
fi
COMPACT_CORAL_LOG="$(resolve_compact_coral_log "$HTC_SUB_CORAL")"

PATHFRAC_LINE_COUNT="$(count_particle_pathfrac_lines "$TEMPLATE_OPT")"
if [[ "$PATHFRAC_LINE_COUNT" -ne 1 ]]; then
    echo "Error: template option file '$TEMPLATE_OPT' must contain exactly one active 'RICHONE ParticlePathFrac' line; found $PATHFRAC_LINE_COUNT." >&2
    exit 1
fi

for PATHFRAC in "${PATHFRAC_VALUES[@]}"; do
    if ! validate_fraction "$PATHFRAC"; then
        echo "Error: invalid ParticlePathFrac '$PATHFRAC'. Expected a number in [0, 1]." >&2
        exit 1
    fi
done

if [[ "$MODE" == "submit" ]]; then
    if (( MAXJOBS < ${#PATHFRAC_VALUES[@]} )); then
        echo "Error: --maxjobs $MAXJOBS is smaller than the number of selected emission points (${#PATHFRAC_VALUES[@]})." >&2
        echo "Please request at least one concurrent job slot per emission point." >&2
        exit 1
    fi

    PER_FRACTION_MAXJOBS=$(( MAXJOBS / ${#PATHFRAC_VALUES[@]} ))
    UNUSED_MAXJOBS=$(( MAXJOBS % ${#PATHFRAC_VALUES[@]} ))
fi

MANIFEST_FILE="$BASE_DIR/settings_files/${TAG}_manifest.txt"
{
    echo "Tag $TAG"
    echo "Mode $MODE"
    echo "TemplateOpt $TEMPLATE_OPT"
    echo "DataList $DATALIST_FILE"
    echo "EnvScript $ENV_SCRIPT"
    echo "OutputBase $OUTPUT_BASE"
    echo "WorkBase $WORK_BASE"
    echo "Fractions ${PATHFRAC_VALUES[*]}"
    echo "HtcSubCoral ${HTC_SUB_CORAL}"
    echo "CompactCoralLog $COMPACT_CORAL_LOG"
    echo "MaxJobsTotal $MAXJOBS"
    if [[ "$MODE" == "submit" ]]; then
        echo "EmissionPoints ${#PATHFRAC_VALUES[@]}"
        echo "PerFractionMaxJobs $PER_FRACTION_MAXJOBS"
        echo "UnusedMaxJobs $UNUSED_MAXJOBS"
    fi
} > "$MANIFEST_FILE"

echo "--- Summary ---"
echo "  mode: $MODE"
echo "  tag: $TAG"
echo "  datalist: $DATALIST_FILE"
echo "  output base: $OUTPUT_BASE"
echo "  work base: $WORK_BASE"
echo "  manifest: $MANIFEST_FILE"
if [[ "$MODE" == "submit" ]]; then
    echo "  total maxjobs: $MAXJOBS"
    echo "  emission points: ${#PATHFRAC_VALUES[@]}"
    echo "  per-emission-point maxjobs: $PER_FRACTION_MAXJOBS"
    echo "  unused maxjobs remainder: $UNUSED_MAXJOBS"
elif [[ "$MODE" == "submit-by-emission-point" ]]; then
    echo "  emission-point submit mode: one DAG per invocation"
    echo "  per-emission-point maxjobs: $MAXJOBS"
fi

SUBMITTED_THIS_RUN=0
for PATHFRAC in "${PATHFRAC_VALUES[@]}"; do
    FRACTION_TAG="$(fraction_tag "$PATHFRAC")"
    FRACTION_TAGS+=("$FRACTION_TAG")
    echo "  fraction: $PATHFRAC"
    echo "    tag: $FRACTION_TAG"

    OPT_FILE="$BASE_DIR/opt_files/${FRACTION_TAG}.opt"
    SETTINGS_FILE="$BASE_DIR/settings_files/${FRACTION_TAG}.txt"
    WORK_DIR="$WORK_BASE/${FRACTION_TAG}"
    FRACTION_OUTPUT_DIR="$OUTPUT_BASE/$FRACTION_TAG"

    mkdir -p "$WORK_DIR"
    mkdir -p "$FRACTION_OUTPUT_DIR"/{mDST,mDST.chunks,hist,hist.chunks,logs}

    if [[ -e "$OPT_FILE" ]]; then
        echo "    reusing option file: $OPT_FILE"
    else
        awk -v pathfrac="$PATHFRAC" '
            BEGIN {
                print "// Generated by submit_pathfrac_scan.sh";
                print "// Per-job raw, mDST, and histogram file paths are injected later by";
                print "// htc_sub_coral / htc_run_coral.";
            }
            $1 == "RICHONE" && $2 == "ParticlePathFrac" {
                print "RICHONE ParticlePathFrac " pathfrac;
                next;
            }
            $1 == "Data" && $2 == "file" { next; }
            $1 == "CsTGEANTFile" && $2 == "file" { next; }
            $1 == "mDST" && $2 == "file" { next; }
            $1 == "histograms" && $2 == "home" { next; }
            { print; }
        ' "$TEMPLATE_OPT" > "$OPT_FILE"
    fi

    if [[ -e "$SETTINGS_FILE" ]]; then
        echo "    reusing settings file: $SETTINGS_FILE"
    else
        cat > "$SETTINGS_FILE" <<EOF
OptionFile   $OPT_FILE
DataList     $DATALIST_FILE
mDstDir      $FRACTION_OUTPUT_DIR/mDST
mDstChunkDir $FRACTION_OUTPUT_DIR/mDST.chunks
HistDir      $FRACTION_OUTPUT_DIR/hist
HistChunkDir $FRACTION_OUTPUT_DIR/hist.chunks
LogDir       $FRACTION_OUTPUT_DIR/logs
EnvScript    $ENV_SCRIPT
CompactCoralLog $COMPACT_CORAL_LOG
EOF
    fi

    WORK_STATE="$(work_dir_state "$WORK_DIR")"
    echo "    work dir state: $WORK_STATE"

    case "$MODE" in
        settings-only)
            ;;
        prepare)
            case "$WORK_STATE" in
                missing|empty)
                    echo "Preparing DAG for ParticlePathFrac = $PATHFRAC"
                    "$HTC_SUB_CORAL" "$SETTINGS_FILE" "$WORK_DIR" -f
                    ;;
                prepared|submitted)
                    echo "Reusing existing work directory for $FRACTION_TAG"
                    ;;
                partial)
                    echo "Error: work directory '$WORK_DIR' contains partial state but no condor.dag. Move it aside or clean it before resuming." >&2
                    exit 1
                    ;;
                *)
                    echo "Error: unknown work directory state '$WORK_STATE' for '$WORK_DIR'." >&2
                    exit 1
                    ;;
            esac
            ;;
        submit)
            case "$WORK_STATE" in
                missing|empty)
                    echo "Preparing and submitting HTCondor for ParticlePathFrac = $PATHFRAC (per-point cap: $PER_FRACTION_MAXJOBS)"
                    "$HTC_SUB_CORAL" "$SETTINGS_FILE" "$WORK_DIR" -f -s "$PER_FRACTION_MAXJOBS"
                    ;;
                prepared)
                    echo "Submitting existing DAG for $FRACTION_TAG (per-point cap: $PER_FRACTION_MAXJOBS)"
                    (
                        cd "$WORK_DIR"
                        condor_submit_dag -maxjobs "$PER_FRACTION_MAXJOBS" condor.dag
                    )
                    ;;
                submitted)
                    echo "Skipping already submitted emission point $FRACTION_TAG"
                    ;;
                partial)
                    echo "Error: work directory '$WORK_DIR' contains partial state but no condor.dag. Move it aside or clean it before resuming." >&2
                    exit 1
                    ;;
                *)
                    echo "Error: unknown work directory state '$WORK_STATE' for '$WORK_DIR'." >&2
                    exit 1
                    ;;
            esac
            ;;
        submit-by-emission-point)
            case "$WORK_STATE" in
                submitted)
                    echo "Skipping already submitted emission point $FRACTION_TAG"
                    ;;
                missing|empty)
                    echo "Preparing and submitting one emission point: $FRACTION_TAG (maxjobs: $MAXJOBS)"
                    "$HTC_SUB_CORAL" "$SETTINGS_FILE" "$WORK_DIR" -f -s "$MAXJOBS"
                    SUBMITTED_THIS_RUN=1
                    break
                    ;;
                prepared)
                    echo "Submitting existing DAG for one emission point: $FRACTION_TAG (maxjobs: $MAXJOBS)"
                    (
                        cd "$WORK_DIR"
                        condor_submit_dag -maxjobs "$MAXJOBS" condor.dag
                    )
                    SUBMITTED_THIS_RUN=1
                    break
                    ;;
                partial)
                    echo "Error: work directory '$WORK_DIR' contains partial state but no condor.dag. Move it aside or clean it before resuming." >&2
                    exit 1
                    ;;
                *)
                    echo "Error: unknown work directory state '$WORK_STATE' for '$WORK_DIR'." >&2
                    exit 1
                    ;;
            esac
            ;;
        *)
            echo "Error: unsupported mode '$MODE'." >&2
            exit 1
            ;;
    esac
done

echo
echo "Preparation complete."
echo "Generated files:"
echo "  options:   $BASE_DIR/opt_files/${TAG}-*.opt"
echo "  settings:  $BASE_DIR/settings_files/${TAG}-*.txt"
echo "  work dirs: $WORK_BASE/${TAG}-*"
if [[ "$MODE" == "settings-only" ]]; then
    echo "No HTCondor preparation/submission was performed."
    echo "Each fraction now has an option file, settings file, and empty work"
    echo "directory ready for later CERN-side preparation."
elif [[ "$MODE" == "submit-by-emission-point" && "$SUBMITTED_THIS_RUN" -eq 0 ]]; then
    echo "No emission point was submitted in this run."
    echo "All selected emission points already look submitted."
fi
