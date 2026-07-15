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
  run_figure3.sh gapbs <bc|bfs|cc|pr> <web|twitter> [options]
  run_figure3.sh spec <numeric-id> [options]

Run and plot the complete Figure 3 comparison:
  Baseline, ANB, DAMON,
  Cache thresholds 16/32/64/96 (epoch 400000/400000), and
  CMS thresholds 16/32/64/96 (epoch 400001/400001).

Options:
  all yes, -y, --yes    Confirm the SPL1 image and every selected step
  --resume              Reuse each valid canonical workload log and run only
                        missing/incomplete points
  --skip-benchmark      Never run hardware; parse and plot existing logs only
  -h, --help            Show this help

Outputs are below AE3/results/figure3/<suite>/<workload>/.
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
        benchmark="$1"; dataset="$2"; shift 2
        case "$benchmark" in bc|bfs|cc|pr) ;; *) ae_die "invalid GAPBS benchmark: $benchmark" ;; esac
        case "$dataset" in web|twitter) ;; *) ae_die "invalid GAPBS database: $dataset" ;; esac
        workload_key="${benchmark}_${dataset}"
        title="GAPBS ${benchmark} (${dataset})"
        ;;
    spec)
        (( $# >= 1 )) || { usage >&2; exit 2; }
        benchmark="$1"; dataset=""; shift
        [[ "$benchmark" =~ ^[0-9]+$ ]] || ae_die "SPEC benchmark must be a numeric ID such as 502"
        workload_key="$benchmark"
        title="SPEC CPU2017 ${benchmark}"
        ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; ae_die "suite must be gapbs or spec" ;;
esac

auto_yes=0
resume=0
skip_benchmark=0
if (( $# >= 2 )) && [[ "$1" == all && "$2" == yes ]]; then
    auto_yes=1
    shift 2
fi
while (( $# > 0 )); do
    case "$1" in
        -y|--yes|--all-yes) auto_yes=1 ;;
        all)
            (( $# >= 2 )) && [[ "$2" == yes ]] || ae_die "'all' must be followed by 'yes'"
            auto_yes=1; shift 2; continue ;;
        --resume) resume=1 ;;
        --skip-benchmark) skip_benchmark=1 ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; ae_die "unknown option: $1" ;;
    esac
    shift
done
(( resume == 0 || skip_benchmark == 0 )) || ae_die "--resume and --skip-benchmark are mutually exclusive"

command -v python3 >/dev/null 2>&1 || ae_die "python3 is required"
python3 -c 'import matplotlib' >/dev/null 2>&1 || \
    ae_die "Python matplotlib is required (for example: python3 -m pip install matplotlib)"
[[ -r "${SCRIPT_DIR}/collect_results.py" ]] || ae_die "missing collector: ${SCRIPT_DIR}/collect_results.py"
[[ -r "${SCRIPT_DIR}/plot_figure3.py" ]] || ae_die "missing plotter: ${SCRIPT_DIR}/plot_figure3.py"

result_dir="${ARTIFACT_DIR}/results/figure3/${suite}/${workload_key}"
out_base="${result_dir}/runs"
manifest="${result_dir}/figure3_manifest.csv"
results_csv="${result_dir}/figure3_results.csv"
plot_prefix="${result_dir}/figure3_normalized_performance"
metadata_file="${result_dir}/run_metadata.txt"
mkdir -p "$out_base"

printf '\nFigure 3 reproduction\n'
printf '  suite/workload : %s / %s\n' "$suite" "$workload_key"
printf '  comparison     : Baseline, ANB, DAMON, Cache th16/32/64/96, CMS th16/32/64/96\n'
printf '  GAPBS metric   : geometric mean of Trial Time 6-10 (exactly 10 trials required)\n'
printf '  SPEC metric    : one successful total-seconds wall time\n'
printf '  plot metric    : Baseline time / method time (higher is better)\n'
printf '  required POF   : SPL1 (sampling every access)\n'
printf '  output         : %s\n\n' "$result_dir"

if (( skip_benchmark == 0 )); then
    ae_confirm "$auto_yes" "Confirm that the SPL1 POF is loaded after a power cycle" || {
        printf 'Stopped before any benchmark.\n'
        exit 0
    }
    ae_load_platform "$ARTIFACT_DIR"
    [[ "$CXL_NODE" == 1 && "$BUFFER_NODE" == 0 ]] || \
        ae_die "Figure 3 requires CXL_NODE=1 and BUFFER_NODE=0; detected CXL_NODE=${CXL_NODE}, BUFFER_NODE=${BUFFER_NODE}"

    benchmark_paths_file="${BENCHMARK_PATHS_FILE:-${SW_DIR}/config/benchmark_paths.env}"
    [[ -r "$benchmark_paths_file" ]] || ae_die "missing benchmark path configuration: $benchmark_paths_file"
    # shellcheck source=/dev/null
    source "$benchmark_paths_file"
    [[ -x "${DAMO_BIN:-}" ]] || \
        ae_die "DAMO_BIN does not resolve to the existing SPR1 damo executable; set it in $benchmark_paths_file"
    [[ -r "${DAMO_CONFIG:-}" ]] || \
        ae_die "DAMO_CONFIG must name the existing readable SPR1 migration-policy JSON in $benchmark_paths_file"
    if [[ "$suite" == gapbs ]]; then
        [[ -d "${GAPBS_ROOT:-}" ]] || ae_die "GAPBS_ROOT is not a directory: ${GAPBS_ROOT:-unset}"
        [[ -x "${GAPBS_ROOT}/${benchmark}" ]] || ae_die "GAPBS binary is not executable: ${GAPBS_ROOT}/${benchmark}"
    else
        [[ -d "${SPEC_ROOT:-}" ]] || ae_die "SPEC_ROOT is not a directory: ${SPEC_ROOT:-unset}"
        [[ -x "${SPEC_RUNCPU:-}" ]] || ae_die "SPEC_RUNCPU is not executable: ${SPEC_RUNCPU:-unset}"
        [[ -r "${SPEC_CONFIG:-}" ]] || ae_die "SPEC_CONFIG is not readable: ${SPEC_CONFIG:-unset}"
    fi
    for threshold in 16 32 64 96; do
        [[ -x "${SW_DIR}/build_option_th${threshold}/migration_manager" ]] || \
            ae_die "threshold ${threshold} manager is not built; run set_default/setup_default.sh build"
    done
    ae_runner_env
fi

write_manifest_header() {
    printf '%s\n' 'order,suite,benchmark,dataset,method,policy,threshold,epoch_a,epoch_b,log_path,label' > "$manifest"
}

append_manifest_row() {
    local order="$1" method="$2" policy="$3" threshold="$4"
    local epoch="$5" log_path="$6" label="$7"
    printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
        "$order" "$suite" "$benchmark" "$dataset" "$method" "$policy" \
        "$threshold" "$epoch" "$epoch" "$log_path" "$label" >> "$manifest"
}

point_paths() {
    local threshold="$1" epoch="$2" method="$3" tag="$4"
    if [[ "$suite" == gapbs ]]; then
        POINT_RUN_DIR="${out_base}/${threshold}_${epoch}_${epoch}_1_${benchmark}_${dataset}_${method}_${tag}"
        POINT_LOG="${POINT_RUN_DIR}/${benchmark}_${dataset}.log"
    else
        POINT_RUN_DIR="${out_base}/${threshold}_${epoch}_${epoch}_1_${benchmark}_${method}_${tag}"
        POINT_LOG="${POINT_RUN_DIR}/${benchmark}.log"
    fi
}

point_valid() {
    if [[ "$suite" == gapbs ]]; then
        ae_gap_run_valid "$POINT_RUN_DIR" "$POINT_LOG"
    else
        ae_spec_run_valid "$POINT_RUN_DIR" "$POINT_LOG"
    fi
}

run_point() {
    local order="$1" method="$2" policy="$3" threshold="$4"
    local epoch="$5" tag="$6" label="$7"
    local manifest_log_path

    point_paths "$threshold" "$epoch" "$method" "$tag"
    manifest_log_path="${POINT_LOG#${result_dir}/}"
    append_manifest_row "$order" "$method" "$policy" "$threshold" "$epoch" "$manifest_log_path" "$label"

    if (( skip_benchmark == 1 )); then
        point_valid || ae_die "canonical run is missing, incomplete, or reports a failed control/cleanup status: $POINT_RUN_DIR"
        return 0
    fi
    if (( resume == 1 )) && point_valid; then
        printf '[%02d/11] reuse valid %s\n' "$order" "$POINT_LOG"
        return 0
    fi

    if [[ -e "$POINT_RUN_DIR" || -e "${POINT_RUN_DIR}.log" ]]; then
        ae_confirm "$auto_yes" "[$order/11] Rerun ${label} and let the runner move old output to .bak?" || {
            printf 'Stopped. Rerun with --resume to continue without repeating valid points.\n'
            exit 0
        }
    else
        ae_confirm "$auto_yes" "[$order/11] Run ${label}?" || {
            printf 'Stopped. Rerun with --resume to continue.\n'
            exit 0
        }
    fi

    extra_env=()
    if [[ "$method" == baseline ]]; then
        extra_env=(
            BASELINE_START_MEMS="$CXL_NODE"
            BASELINE_MEMS="$CXL_NODE"
            BASELINE_MEM_POLICY=membind
            BASELINE_EXPAND_DELAY_SEC=2
        )
    fi

    if [[ "$suite" == gapbs ]]; then
        ae_run_gapbs_point "$SW_DIR" "$out_base" "$threshold" "$epoch" \
            "$benchmark" "$dataset" "$method" "$tag" "${extra_env[@]}"
    else
        ae_run_spec_point "$SW_DIR" "$out_base" "$threshold" "$epoch" \
            "$benchmark" "$method" "$tag" "${extra_env[@]}"
    fi
    point_valid || ae_die "runner returned success but the workload log is incomplete: $POINT_LOG"
}

write_manifest_header
run_point 1 baseline baseline 16 400000 fig3_baseline Baseline
run_point 2 anb anb 16 400000 fig3_anb ANB
run_point 3 damon damon 16 400000 fig3_damon DAMON

order=4
for threshold in 16 32 64 96; do
    run_point "$order" mig cache "$threshold" 400000 \
        "fig3_cache_th${threshold}" "Cache-${threshold}"
    order=$((order + 1))
done
for threshold in 16 32 64 96; do
    run_point "$order" mig cms "$threshold" 400001 \
        "fig3_cms_th${threshold}" "CMS-${threshold}"
    order=$((order + 1))
done

if (( skip_benchmark == 1 )); then
    printf '[1/3] Benchmark skipped; canonical logs and runtime summaries validated.\n'
else
    printf '[1/3] All eleven benchmark points completed or reused.\n'
fi

printf '[2/3] Parse runtime logs and normalize to Baseline.\n'
python3 "${SCRIPT_DIR}/collect_results.py" \
    --suite "$suite" --manifest "$manifest" --output "$results_csv"

printf '[3/3] Plot normalized performance.\n'
python3 "${SCRIPT_DIR}/plot_figure3.py" \
    --input "$results_csv" --output-prefix "$plot_prefix" \
    --title "Figure 3: ${title}"

{
    printf 'experiment=figure3\n'
    printf 'suite=%s\nworkload=%s\n' "$suite" "$workload_key"
    printf 'required_pof=SPL1\n'
    if (( skip_benchmark == 1 )); then
        printf 'pof_confirmation=not_requested_processing_only\n'
    else
        printf 'pof_confirmation=reviewer_confirmed_before_run\n'
    fi
    printf 'baseline_placement=cxl_membind\n'
    printf 'cache_epoch=400000\ncms_epoch=400001\npoll_ms=1\n'
    printf 'normalized_performance=baseline_seconds/runtime_seconds\n'
    printf 'completed_at=%s\n' "$(TZ=America/Chicago date --iso-8601=seconds)"
} > "$metadata_file"

printf '\nFigure 3 outputs\n'
printf '  metadata : %s\n' "$metadata_file"
printf '  manifest : %s\n' "$manifest"
printf '  results  : %s\n' "$results_csv"
printf '  plot     : %s.png\n' "$plot_prefix"
printf '  plot     : %s.pdf\n' "$plot_prefix"
