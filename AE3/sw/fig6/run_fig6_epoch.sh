#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SW_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
ARTIFACT_DIR="$(cd -- "${SW_DIR}/.." && pwd)"
# shellcheck source=../benchmark/ae_reproduction_common.sh
source "${SW_DIR}/benchmark/ae_reproduction_common.sh"

usage() {
    cat <<'EOF'
Usage:
  run_fig6_epoch.sh gapbs <bc|bfs|cc|pr> <web|twitter> [options]
  run_fig6_epoch.sh spec <numeric-id> [options]

Optional Figure 6 epoch sweep (threshold 64, SPL1 POF):
  Cache: 400000, 4000000, 40000000, 400000000
  CMS:   400001, 4000001, 40000001, 400000001

Options:
  --method <cache|cms|both>       Default: both
  --epoch <1|10|100|1000|all>    Epoch in milliseconds; default: all
  --resume                       Reuse valid canonical logs; run only missing points
  -y, --yes, all yes             Confirm SPL1 and reruns without questions
  -h, --help                     Show this help

This script never programs a POF or reboots SPR1.
EOF
}

(( $# > 0 )) || { usage >&2; exit 2; }
suite="$1"
shift
case "$suite" in
    gap|gapbs)
        suite="gapbs"
        (( $# >= 2 )) || { usage >&2; exit 2; }
        benchmark="$1"
        database="$2"
        shift 2
        case "$benchmark" in bc|bfs|cc|pr) ;; *) ae_die "invalid GAPBS benchmark: $benchmark" ;; esac
        case "$database" in web|twitter) ;; *) ae_die "invalid GAPBS database: $database" ;; esac
        workload_key="${benchmark}_${database}"
        ;;
    spec)
        (( $# >= 1 )) || { usage >&2; exit 2; }
        benchmark="$1"
        database=""
        shift
        [[ "$benchmark" =~ ^[0-9]+$ ]] || ae_die "SPEC benchmark must be a numeric ID"
        workload_key="$benchmark"
        ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; ae_die "suite must be gapbs or spec" ;;
esac

method="both"
epoch_choice="all"
auto_yes=0
resume=0
if (( $# >= 2 )) && [[ "$1" == all && "$2" == yes ]]; then
    auto_yes=1
    shift 2
fi
while (( $# > 0 )); do
    case "$1" in
        --method)
            (( $# >= 2 )) || ae_die "--method requires a value"
            method="$2"; shift 2; continue ;;
        --epoch)
            (( $# >= 2 )) || ae_die "--epoch requires a value"
            epoch_choice="$2"; shift 2; continue ;;
        --resume) resume=1 ;;
        -y|--yes|--all-yes) auto_yes=1 ;;
        all)
            (( $# >= 2 )) && [[ "$2" == yes ]] || ae_die "'all' must be followed by 'yes'"
            auto_yes=1; shift 2; continue ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; ae_die "unknown option: $1" ;;
    esac
    shift
done
case "$method" in cache|cms|both) ;; *) ae_die "--method must be cache, cms, or both" ;; esac
case "$epoch_choice" in 1|10|100|1000|all) ;; *) ae_die "--epoch must be 1, 10, 100, 1000, or all" ;; esac

printf '\nOptional Figure 6 epoch sweep\n'
printf '  suite/workload : %s / %s\n' "$suite" "$workload_key"
printf '  threshold/poll : 64 / 1 ms\n'
printf '  methods        : %s\n' "$method"
printf '  epoch choice   : %s ms\n' "$epoch_choice"
printf '  required POF   : SPL1 (sampling every access)\n'
printf '  note           : this script cannot detect or program the loaded POF\n\n'
ae_confirm "$auto_yes" "Confirm that the SPL1 POF is loaded after a power cycle" || {
    printf 'Stopped before any benchmark.\n'
    exit 0
}

ae_load_platform "$ARTIFACT_DIR"
ae_runner_env
out_base="${ARTIFACT_DIR}/results/figure6/${suite}/${workload_key}/runs"
mkdir -p "$out_base"
point_records=()

if [[ "$epoch_choice" == all ]]; then
    epoch_ms_values=(1 10 100 1000)
else
    epoch_ms_values=("$epoch_choice")
fi
if [[ "$method" == both ]]; then
    methods=(cache cms)
else
    methods=("$method")
fi

epoch_cycles() {
    local method_name="$1"
    local epoch_ms="$2"
    local even
    even=$((400000 * epoch_ms))
    if [[ "$method_name" == cms ]]; then
        printf '%s\n' $((even + 1))
    else
        printf '%s\n' "$even"
    fi
}

for method_name in "${methods[@]}"; do
    for epoch_ms in "${epoch_ms_values[@]}"; do
        epoch="$(epoch_cycles "$method_name" "$epoch_ms")"
        tag="fig6_${method_name}_${epoch_ms}ms"
        if [[ "$suite" == gapbs ]]; then
            run_dir="${out_base}/64_${epoch}_${epoch}_1_${benchmark}_${database}_mig_${tag}"
            workload_log="${run_dir}/${benchmark}_${database}.log"
            if (( resume == 1 )) && ae_gap_run_valid "$run_dir" "$workload_log"; then
                printf '[reuse] %s\n' "$workload_log"
                point_records+=("${method_name},${epoch_ms}ms,reused,${run_dir}")
                continue
            fi
        else
            run_dir="${out_base}/64_${epoch}_${epoch}_1_${benchmark}_mig_${tag}"
            workload_log="${run_dir}/${benchmark}.log"
            if (( resume == 1 )) && ae_spec_run_valid "$run_dir" "$workload_log"; then
                printf '[reuse] %s\n' "$workload_log"
                point_records+=("${method_name},${epoch_ms}ms,reused,${run_dir}")
                continue
            fi
        fi

        if [[ -e "$run_dir" || -e "${run_dir}.log" ]]; then
            ae_confirm "$auto_yes" "Rerun ${method_name} at ${epoch_ms} ms and let the runner move old output to .bak?" || {
                printf '[skip] %s\n' "$run_dir"
                point_records+=("${method_name},${epoch_ms}ms,skipped_by_user,${run_dir}")
                continue
            }
        else
            ae_confirm "$auto_yes" "Run ${method_name} at ${epoch_ms} ms?" || {
                printf '[skip] %s\n' "$run_dir"
                point_records+=("${method_name},${epoch_ms}ms,skipped_by_user,${run_dir}")
                continue
            }
        fi

        if [[ "$suite" == gapbs ]]; then
            ae_run_gapbs_point "$SW_DIR" "$out_base" 64 "$epoch" \
                "$benchmark" "$database" mig "$tag"
        else
            ae_run_spec_point "$SW_DIR" "$out_base" 64 "$epoch" \
                "$benchmark" mig "$tag"
        fi
        if [[ "$suite" == gapbs ]]; then
            ae_gap_run_valid "$run_dir" "$workload_log" || ae_die "completed point failed validation: $run_dir"
        else
            ae_spec_run_valid "$run_dir" "$workload_log" || ae_die "completed point failed validation: $run_dir"
        fi
        point_records+=("${method_name},${epoch_ms}ms,completed,${run_dir}")
    done
done

manifest="${ARTIFACT_DIR}/results/figure6/${suite}/${workload_key}/run_manifest.txt"
{
    printf 'experiment=figure6_epoch\n'
    printf 'suite=%s\nworkload=%s\n' "$suite" "$workload_key"
    printf 'declared_pof=SPL1\nthreshold=64\npoll_ms=1\n'
    printf 'method=%s\nepoch_selection_ms=%s\n' "$method" "$epoch_choice"
    for point_record in "${point_records[@]}"; do
        printf 'point=%s\n' "$point_record"
    done
    printf 'recorded_at=%s\n' "$(TZ=America/Chicago date --iso-8601=seconds)"
} > "$manifest"
printf '\nSaved optional run manifest: %s\n' "$manifest"
