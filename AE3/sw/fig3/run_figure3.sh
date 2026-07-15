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

Run the complete Figure 3 comparison or one canonical case:
  Baseline, ANB, DAMON,
  Cache thresholds 16/32/64/96 (epoch 400000/400000), and
  CMS thresholds 16/32/64/96 (epoch 400001/400001).

Options:
  --case <name>         all (default), baseline, anb, damon, cache16,
                        cache32, cache64, cache96, cms16, cms32, cms64,
                        or cms96
  all yes, -y, --yes    Confirm the SPL1 image and every selected step
  --resume              Reuse each valid selected canonical workload log and
                        run only a missing/incomplete selected point
  --skip-benchmark      Never run hardware; validate all eleven canonical logs
                        and collect the CSV; plot unless --skip-plot is added
  --skip-plot           Complete data collection/CSV generation without
                        importing Matplotlib; plot later with --skip-benchmark
  -h, --help            Show this help

CSV collection and plotting require the complete eleven-case sweep. A single
--case invocation updates only that canonical run and the deterministic full
manifest; use --case all --resume after individual cases to collect the CSV.

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
skip_plot=0
selected_case="all"
if (( $# >= 2 )) && [[ "$1" == all && "$2" == yes ]]; then
    auto_yes=1
    shift 2
fi
while (( $# > 0 )); do
    case "$1" in
        --case)
            (( $# >= 2 )) || ae_die "--case requires a value"
            selected_case="${2,,}"
            shift 2
            continue
            ;;
        -y|--yes|--all-yes) auto_yes=1 ;;
        all)
            (( $# >= 2 )) && [[ "$2" == yes ]] || ae_die "'all' must be followed by 'yes'"
            auto_yes=1; shift 2; continue
            ;;
        --resume) resume=1 ;;
        --skip-benchmark) skip_benchmark=1 ;;
        --skip-plot) skip_plot=1 ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; ae_die "unknown option: $1" ;;
    esac
    shift
done
case "$selected_case" in
    all|baseline|anb|damon|cache16|cache32|cache64|cache96|cms16|cms32|cms64|cms96) ;;
    *) ae_die "--case must be one of: all, baseline, anb, damon, cache16, cache32, cache64, cache96, cms16, cms32, cms64, cms96" ;;
esac
(( resume == 0 || skip_benchmark == 0 )) || ae_die "--resume and --skip-benchmark are mutually exclusive"
if (( skip_benchmark == 1 )) && [[ "$selected_case" != all ]]; then
    ae_die "--skip-benchmark processes the complete sweep and requires --case all"
fi

command -v python3 >/dev/null 2>&1 || ae_die "python3 is required"
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
printf '  selected case  : %s\n' "$selected_case"
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
    if [[ "$selected_case" == all || "$selected_case" == damon ]]; then
        [[ -x "${DAMO_BIN:-}" ]] || \
            ae_die "DAMO_BIN does not resolve to the existing SPR1 damo executable; set it in $benchmark_paths_file"
        [[ -r "${DAMO_CONFIG:-}" ]] || \
            ae_die "DAMO_CONFIG must name the existing readable SPR1 migration-policy JSON in $benchmark_paths_file"
    fi
    if [[ "$suite" == gapbs ]]; then
        [[ -d "${GAPBS_ROOT:-}" ]] || ae_die "GAPBS_ROOT is not a directory: ${GAPBS_ROOT:-unset}"
        [[ -x "${GAPBS_ROOT}/${benchmark}" ]] || ae_die "GAPBS binary is not executable: ${GAPBS_ROOT}/${benchmark}"
    else
        [[ -d "${SPEC_ROOT:-}" ]] || ae_die "SPEC_ROOT is not a directory: ${SPEC_ROOT:-unset}"
        [[ -x "${SPEC_RUNCPU:-}" ]] || ae_die "SPEC_RUNCPU is not executable: ${SPEC_RUNCPU:-unset}"
        [[ -r "${SPEC_CONFIG:-}" ]] || ae_die "SPEC_CONFIG is not readable: ${SPEC_CONFIG:-unset}"
    fi

    if [[ "$selected_case" == all ]]; then
        required_thresholds=(16 32 64 96)
    elif [[ "$selected_case" =~ ^(cache|cms)(16|32|64|96)$ ]]; then
        required_thresholds=("${BASH_REMATCH[2]}")
    else
        required_thresholds=(16)
    fi
    for threshold in "${required_thresholds[@]}"; do
        [[ -x "${SW_DIR}/build_option_th${threshold}/migration_manager" ]] || \
            ae_die "threshold ${threshold} manager is not built; run set_default/setup_default.sh build"
    done
    ae_runner_env
fi

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

append_manifest_point() {
    local order="$1" method="$2" policy="$3" threshold="$4"
    local epoch="$5" tag="$6" label="$7"
    local manifest_log_path

    point_paths "$threshold" "$epoch" "$method" "$tag"
    manifest_log_path="${POINT_LOG#${result_dir}/}"
    printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
        "$order" "$suite" "$benchmark" "$dataset" "$method" "$policy" \
        "$threshold" "$epoch" "$epoch" "$manifest_log_path" "$label" >> "$manifest"
}

write_full_manifest() {
    printf '%s\n' 'order,suite,benchmark,dataset,method,policy,threshold,epoch_a,epoch_b,log_path,label' > "$manifest"
    append_manifest_point 1 baseline baseline 16 400000 fig3_baseline Baseline
    append_manifest_point 2 anb anb 16 400000 fig3_anb ANB
    append_manifest_point 3 damon damon 16 400000 fig3_damon DAMON
    append_manifest_point 4 mig cache 16 400000 fig3_cache_th16 Cache-16
    append_manifest_point 5 mig cache 32 400000 fig3_cache_th32 Cache-32
    append_manifest_point 6 mig cache 64 400000 fig3_cache_th64 Cache-64
    append_manifest_point 7 mig cache 96 400000 fig3_cache_th96 Cache-96
    append_manifest_point 8 mig cms 16 400001 fig3_cms_th16 CMS-16
    append_manifest_point 9 mig cms 32 400001 fig3_cms_th32 CMS-32
    append_manifest_point 10 mig cms 64 400001 fig3_cms_th64 CMS-64
    append_manifest_point 11 mig cms 96 400001 fig3_cms_th96 CMS-96
}

run_point() {
    local order="$1" method="$2" policy="$3" threshold="$4"
    local epoch="$5" tag="$6" label="$7"

    point_paths "$threshold" "$epoch" "$method" "$tag"
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

process_case() {
    case "$1" in
        baseline) run_point 1 baseline baseline 16 400000 fig3_baseline Baseline ;;
        anb) run_point 2 anb anb 16 400000 fig3_anb ANB ;;
        damon) run_point 3 damon damon 16 400000 fig3_damon DAMON ;;
        cache16) run_point 4 mig cache 16 400000 fig3_cache_th16 Cache-16 ;;
        cache32) run_point 5 mig cache 32 400000 fig3_cache_th32 Cache-32 ;;
        cache64) run_point 6 mig cache 64 400000 fig3_cache_th64 Cache-64 ;;
        cache96) run_point 7 mig cache 96 400000 fig3_cache_th96 Cache-96 ;;
        cms16) run_point 8 mig cms 16 400001 fig3_cms_th16 CMS-16 ;;
        cms32) run_point 9 mig cms 32 400001 fig3_cms_th32 CMS-32 ;;
        cms64) run_point 10 mig cms 64 400001 fig3_cms_th64 CMS-64 ;;
        cms96) run_point 11 mig cms 96 400001 fig3_cms_th96 CMS-96 ;;
        *) ae_die "internal error: unsupported case $1" ;;
    esac
}

validate_point() {
    local order="$1" method="$2" threshold="$3" epoch="$4" tag="$5" label="$6"
    point_paths "$threshold" "$epoch" "$method" "$tag"
    point_valid || ae_die "canonical ${label} run is missing, incomplete, or reports a failed control/cleanup status: $POINT_RUN_DIR"
    printf '[validate %02d/11] %s\n' "$order" "$label"
}

validate_full_sweep() {
    validate_point 1 baseline 16 400000 fig3_baseline Baseline
    validate_point 2 anb 16 400000 fig3_anb ANB
    validate_point 3 damon 16 400000 fig3_damon DAMON
    validate_point 4 mig 16 400000 fig3_cache_th16 Cache-16
    validate_point 5 mig 32 400000 fig3_cache_th32 Cache-32
    validate_point 6 mig 64 400000 fig3_cache_th64 Cache-64
    validate_point 7 mig 96 400000 fig3_cache_th96 Cache-96
    validate_point 8 mig 16 400001 fig3_cms_th16 CMS-16
    validate_point 9 mig 32 400001 fig3_cms_th32 CMS-32
    validate_point 10 mig 64 400001 fig3_cms_th64 CMS-64
    validate_point 11 mig 96 400001 fig3_cms_th96 CMS-96
}

write_metadata() {
    local plot_status="$1"
    local data_status="$2"
    {
        printf 'experiment=figure3\n'
        printf 'suite=%s\nworkload=%s\n' "$suite" "$workload_key"
        printf 'selected_case=%s\n' "$selected_case"
        printf 'required_pof=SPL1\n'
        if (( skip_benchmark == 1 )); then
            printf 'pof_confirmation=not_requested_processing_only\n'
        else
            printf 'pof_confirmation=reviewer_confirmed_before_run\n'
        fi
        printf 'data_status=%s\n' "$data_status"
        printf 'plot_status=%s\n' "$plot_status"
        printf 'baseline_placement=cxl_membind\n'
        printf 'cache_epoch=400000\ncms_epoch=400001\npoll_ms=1\n'
        printf 'normalized_performance=baseline_seconds/runtime_seconds\n'
        printf 'completed_at=%s\n' "$(TZ=America/Chicago date --iso-8601=seconds)"
    } > "$metadata_file"
}

print_full_outputs() {
    local include_plots="$1"
    printf '\nFigure 3 outputs\n'
    printf '  metadata : %s\n' "$metadata_file"
    printf '  manifest : %s\n' "$manifest"
    printf '  results  : %s\n' "$results_csv"
    if [[ "$include_plots" == 1 ]]; then
        printf '  plot     : %s.png\n' "$plot_prefix"
        printf '  plot     : %s.pdf\n' "$plot_prefix"
    fi
}

write_full_manifest

if (( skip_benchmark == 1 )); then
    validate_full_sweep
    printf '[1/3] Benchmark skipped; all canonical logs and runtime summaries validated.\n'
elif [[ "$selected_case" == all ]]; then
    for case_name in baseline anb damon cache16 cache32 cache64 cache96 cms16 cms32 cms64 cms96; do
        process_case "$case_name"
    done
    printf '[1/3] All eleven benchmark points completed or reused.\n'
else
    process_case "$selected_case"
    write_metadata not_run_partial_case selected_case_completed
    printf '\nFigure 3 case completed: %s\n' "$selected_case"
    printf '  manifest : %s (deterministic full 11-case manifest)\n' "$manifest"
    printf '  output   : %s\n' "$POINT_RUN_DIR"
    printf 'Run the remaining cases, then use --case all --resume --skip-plot to collect the complete CSV.\n'
    exit 0
fi

printf '[2/3] Parse runtime logs and normalize to Baseline.\n'
python3 "${SCRIPT_DIR}/collect_results.py" \
    --suite "$suite" --manifest "$manifest" --output "$results_csv"

if (( skip_plot == 1 )); then
    printf '[3/3] Plot skipped as requested; the validated CSV is ready.\n'
    write_metadata skipped_by_option complete_full_sweep
    print_full_outputs 0
    exit 0
fi

printf '[3/3] Plot normalized performance.\n'
if ! python3 -c 'import matplotlib' >/dev/null 2>&1; then
    printf 'WARNING: Matplotlib is unavailable or incompatible in the current Python environment.\n' >&2
    printf 'The complete benchmark data and CSV are valid; only PNG/PDF plotting was skipped.\n' >&2
    printf 'Run again with --skip-benchmark from the plotting environment.\n' >&2
    write_metadata skipped_matplotlib_unavailable complete_full_sweep
    print_full_outputs 0
    exit 0
fi

if python3 "${SCRIPT_DIR}/plot_figure3.py" \
    --input "$results_csv" --output-prefix "$plot_prefix" \
    --title "Figure 3: ${title}"; then
    write_metadata completed complete_full_sweep
    print_full_outputs 1
else
    write_metadata failed complete_full_sweep
    ae_die "Figure 3 plotting failed after successful CSV collection: $results_csv"
fi
