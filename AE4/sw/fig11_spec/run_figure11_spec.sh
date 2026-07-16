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
  run_figure11_spec.sh <gcc|mcf|cactuB|cam4|roms> [options]

Run the optional Figure-11-style comparison for one restricted SPEC CPU 2017
benchmark. Each fixed method and each adaptive direction is invoked five
complete times. The final anchored "; <seconds> total seconds elapsed" value
from each invocation is used. The faster of the two complete adaptive
candidates is reported as the single Adaptive bar, and the plot reports
CXL-only geometric-mean time / method geometric-mean time.

Methods:
  CXL-only       no migration, Node 1 only
  CHMU-Cache     static 400000/400000
  CHMU-CMS       static 400001/400001
  Adaptive       supplied SPEC LOBO cfg; compare 400000/400001 and
                 400001/400000, then report the faster complete direction

Options:
  --threshold <16|32|64|96>  Runtime CHMU threshold (default: 16)
  all yes, -y, --yes         Confirm the SPL1 image and all benchmark runs
  --resume                   Reuse valid canonical runs; rerun only invalid or
                             missing runs
  --skip-benchmark           Validate and collect existing canonical logs only;
                             plot unless --skip-plot is added
  --skip-plot                Run/validate benchmarks and, once the full sweep
                             exists, collect CSV without importing Matplotlib
  --method, --case <name>    Run only all, cxl, cache, cms, or adaptive;
                             adaptive runs both epoch directions. Advanced
                             selectors adaptive_400000_400001 and
                             adaptive_400001_400000 run one direction only
                             (local additionally requires --include-local)
  --include-local            Add optional Local-only; running requires
                             CONFIRM_LOCAL_MEMMAP=YES after a memory-map reboot
  -h, --help                 Show this help

Environment:
  FIG11_CASE_INTERVAL_SEC    Delay between newly executed canonical units
                             (default: 30; use 0 to disable)
  FIG11_LOCK_RETRY_INTERVAL_SEC
                             Delay between retries when the shared ARC host
                             lock is temporarily busy (default: 10)
  FIG11_LOCK_RETRY_TIMEOUT_SEC
                             Maximum total lock-retry wait for one unit
                             (default: 300; use 0 to disable automatic retry)

This is an optional extension; the reviewer Figure 11 path remains GAPBS.
This script never programs a POF or reboots SPR1.
EOF
}

(( $# > 0 )) || { usage >&2; exit 2; }
selector="$1"
shift
case "$selector" in
    gcc|502) benchmark=502; workload_key=502; display_name=gcc ;;
    mcf|505) benchmark=505; workload_key=505; display_name=mcf ;;
    cactuB|cactub|cactuBSSN|507)
        benchmark=507; workload_key=507; display_name=cactuB ;;
    cam4|527) benchmark=527; workload_key=527; display_name=cam4 ;;
    roms|554) benchmark=554; workload_key=554; display_name=roms ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; ae_die "unsupported optional SPEC workload: $selector" ;;
esac

threshold=16
auto_yes=0
resume=0
skip_benchmark=0
skip_plot=0
include_local=0
selected_method=all
FIG11_CASE_INTERVAL_SEC="${FIG11_CASE_INTERVAL_SEC:-30}"
FIG11_LOCK_RETRY_INTERVAL_SEC="${FIG11_LOCK_RETRY_INTERVAL_SEC:-10}"
FIG11_LOCK_RETRY_TIMEOUT_SEC="${FIG11_LOCK_RETRY_TIMEOUT_SEC:-300}"
while (( $# > 0 )); do
    case "$1" in
        --threshold)
            (( $# >= 2 )) || ae_die "--threshold requires a value"
            threshold="$2"; shift 2; continue ;;
        -y|--yes|--all-yes) auto_yes=1 ;;
        all)
            (( $# >= 2 )) && [[ "$2" == yes ]] || \
                ae_die "'all' must be followed by 'yes'"
            auto_yes=1; shift 2; continue ;;
        --resume) resume=1 ;;
        --skip-benchmark) skip_benchmark=1 ;;
        --skip-plot) skip_plot=1 ;;
        --method|--case)
            (( $# >= 2 )) || ae_die "$1 requires a value"
            selected_method="$2"; shift 2; continue ;;
        --include-local) include_local=1 ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; ae_die "unknown option: $1" ;;
    esac
    shift
done
case "$threshold" in
    16|32|64|96) ;;
    *) ae_die "threshold must be 16, 32, 64, or 96" ;;
esac
(( resume == 0 || skip_benchmark == 0 )) || \
    ae_die "--resume and --skip-benchmark are mutually exclusive"
case "$selected_method" in
    all|cxl|cache|cms|adaptive|adaptive_400000_400001|adaptive_400001_400000) ;;
    local)
        (( include_local == 1 )) || \
            ae_die "--method local requires --include-local and CONFIRM_LOCAL_MEMMAP=YES when running"
        ;;
    *) ae_die "--method/--case must be one of: all, cxl, cache, cms, adaptive, adaptive_400000_400001, adaptive_400001_400000, local" ;;
esac
if (( skip_benchmark == 1 )) && [[ "$selected_method" != all ]]; then
    ae_die "--skip-benchmark processes the complete sweep and therefore requires --method all"
fi
[[ "$FIG11_CASE_INTERVAL_SEC" =~ ^[0-9]+$ ]] || \
    ae_die "FIG11_CASE_INTERVAL_SEC must be a non-negative integer"
[[ "$FIG11_LOCK_RETRY_INTERVAL_SEC" =~ ^[1-9][0-9]*$ ]] || \
    ae_die "FIG11_LOCK_RETRY_INTERVAL_SEC must be a positive integer"
[[ "$FIG11_LOCK_RETRY_TIMEOUT_SEC" =~ ^[0-9]+$ ]] || \
    ae_die "FIG11_LOCK_RETRY_TIMEOUT_SEC must be a non-negative integer"
CHMU_SPEC_COPIES="${CHMU_SPEC_COPIES:-8}"
[[ "$CHMU_SPEC_COPIES" =~ ^[1-9][0-9]*$ ]] || \
    ae_die "CHMU_SPEC_COPIES must be a positive decimal integer"

command -v python3 >/dev/null 2>&1 || ae_die "python3 is required"
command -v sha256sum >/dev/null 2>&1 || ae_die "sha256sum is required"
[[ -r "${SCRIPT_DIR}/collect_spec_results.py" ]] || \
    ae_die "missing optional SPEC collector"
[[ -r "${SW_DIR}/fig11/plot_figure11.py" ]] || \
    ae_die "missing shared Figure 11 plotter"

model_dir="${SW_DIR}/ml/pretrained/th${threshold}/spec"
[[ -d "$model_dir" ]] || \
    ae_die "pretrained SPEC configuration directory is missing for threshold ${threshold}: $model_dir"
pretrained_model_cfg="$(cd -- "$model_dir" && pwd)/${workload_key}.cfg"
ae_validate_model_cfg "$pretrained_model_cfg" "$workload_key"
model_cfg_sha256="$(sha256sum "$pretrained_model_cfg" | awk '{print $1}')"

results_root="${AE4_RESULTS_ROOT:-${ARTIFACT_DIR}/results}"
mkdir -p "$results_root"
results_root="$(cd -- "$results_root" && pwd)"
result_dir="${results_root}/figure11_optional_spec/th${threshold}/${workload_key}"
out_base="${result_dir}/runs"
manifest="${result_dir}/figure11_spec_manifest.csv"
summary_csv="${result_dir}/figure11_spec_results.csv"
samples_csv="${result_dir}/figure11_spec_selected_samples.csv"
plot_prefix="${result_dir}/figure11_spec_normalized_performance"
metadata_file="${result_dir}/run_metadata.txt"
mkdir -p "$out_base"

# The adaptive manager log records this immutable content-addressed path. This
# prevents --resume/--skip-benchmark from mixing runs made with different cfgs.
model_snapshot_dir="${result_dir}/configuration_snapshots"
model_cfg="${model_snapshot_dir}/${workload_key}_${model_cfg_sha256}.cfg"
mkdir -p "$model_snapshot_dir"
if [[ ! -e "$model_cfg" ]]; then
    model_cfg_tmp="${model_cfg}.tmp.$$"
    cp -- "$pretrained_model_cfg" "$model_cfg_tmp"
    chmod 0444 "$model_cfg_tmp"
    mv -- "$model_cfg_tmp" "$model_cfg"
fi
[[ -f "$model_cfg" && ! -L "$model_cfg" && -r "$model_cfg" ]] || \
    ae_die "adaptive cfg snapshot is not a readable regular file: $model_cfg"
[[ "$(sha256sum "$model_cfg" | awk '{print $1}')" == "$model_cfg_sha256" ]] || \
    ae_die "adaptive cfg snapshot hash mismatch; do not modify result snapshots: $model_cfg"
chmod 0444 "$model_cfg"
ae_validate_model_cfg "$model_cfg" "$workload_key"

methods=(cxl cache cms adaptive_400000_400001 adaptive_400001_400000)
labels=(
    "CXL-only"
    "CHMU-Cache"
    "CHMU-CMS"
    "Adaptive (400000/400001)"
    "Adaptive (400001/400000)"
)
if (( include_local == 1 )); then
    methods=(local "${methods[@]}")
    labels=("Local-only" "${labels[@]}")
fi

printf '\nOptional SPEC Figure 11-style comparison\n'
printf '  workload       : %s (SPEC %s)\n' "$display_name" "$workload_key"
printf '  threshold      : %s\n' "$threshold"
printf '  methods        : %s\n' "${labels[*]}"
printf '  selected case  : %s\n' "$selected_method"
printf '  repetitions    : 5 complete SPEC invocations per fixed method and adaptive direction\n'
printf '  selected data  : final total-seconds record per invocation (5 samples/candidate)\n'
printf '  adaptive bar   : faster complete direction by 5-sample geometric-mean time\n'
printf '  plot metric    : CXL-only time / method time (higher is better)\n'
printf '  SPEC copies    : %s\n' "$CHMU_SPEC_COPIES"
printf '  supplied cfg   : %s\n' "$pretrained_model_cfg"
printf '  frozen cfg     : %s\n' "$model_cfg"
printf '  cfg SHA-256    : %s\n' "$model_cfg_sha256"
printf '  required POF   : SPL1\n'
printf '  output         : %s\n\n' "$result_dir"

if (( skip_benchmark == 0 )); then
    ae_confirm "$auto_yes" "Confirm that the SPL1 POF is loaded after a power cycle" || {
        printf 'Stopped before any benchmark.\n'
        exit 0
    }
    ae_load_platform "$ARTIFACT_DIR"
    [[ "$CXL_NODE" == 1 && "$BUFFER_NODE" == 0 ]] || \
        ae_die "optional SPEC comparison requires CXL_NODE=1 and BUFFER_NODE=0; detected CXL_NODE=${CXL_NODE}, BUFFER_NODE=${BUFFER_NODE}"
    [[ -x "${SW_DIR}/build_option_th${threshold}/migration_manager" ]] || \
        ae_die "threshold ${threshold} manager is not built; run set_default/setup_default.sh build"
    command -v numactl >/dev/null 2>&1 || ae_die "numactl is required for CXL-only placement"

    benchmark_paths_file="${BENCHMARK_PATHS_FILE:-${SW_DIR}/config/benchmark_paths.env}"
    [[ -r "$benchmark_paths_file" ]] || \
        ae_die "missing benchmark path configuration: $benchmark_paths_file"
    # shellcheck source=/dev/null
    source "$benchmark_paths_file"
    [[ -d "${SPEC_ROOT:-}" ]] || \
        ae_die "SPEC_ROOT is not a directory: ${SPEC_ROOT:-unset}"
    [[ -x "${SPEC_RUNCPU:-}" ]] || \
        ae_die "SPEC_RUNCPU is not executable: ${SPEC_RUNCPU:-unset}"
    [[ -r "${SPEC_CONFIG:-}" ]] || \
        ae_die "SPEC_CONFIG is not readable: ${SPEC_CONFIG:-unset}"
    if [[ "$selected_method" == all || "$selected_method" == adaptive ||
          "$selected_method" == adaptive_400000_400001 ||
          "$selected_method" == adaptive_400001_400000 ]]; then
        ae_validate_perf_binary "${CHMU_PERF_BIN:-}"
    fi

    if (( include_local == 1 )); then
        [[ "${CONFIRM_LOCAL_MEMMAP:-}" == YES ]] || \
            ae_die "Local-only needs a reboot-time memory-map change that gives Node 0 enough capacity; after verifying it, rerun with CONFIRM_LOCAL_MEMMAP=YES"
        ae_confirm "$auto_yes" "Confirm that SPR1 was rebooted with sufficient Node 0 capacity for Local-only" || {
            printf 'Stopped before any benchmark.\n'
            exit 0
        }
    fi
    ae_runner_env
fi

set_point() {
    local method="$1"
    local repeat="$2"
    local repeat_tag
    printf -v repeat_tag '%02d' "$repeat"

    POINT_METHOD="$method"
    POINT_MODE=mig
    POINT_EPOCH_A=400000
    POINT_EPOCH_B=400001
    POINT_TAG="fig11spec_${method}_rep${repeat_tag}"
    case "$method" in
        local|cxl)
            POINT_MODE=baseline
            POINT_EPOCH_A=400000
            POINT_EPOCH_B=400000
            ;;
        cache)
            POINT_EPOCH_A=400000
            POINT_EPOCH_B=400000
            ;;
        cms)
            POINT_EPOCH_A=400001
            POINT_EPOCH_B=400001
            ;;
        adaptive_400000_400001)
            # Preserve the original forward-direction canonical path so that
            # --resume can reuse valid 400000/400001 repetitions.
            POINT_TAG="fig11spec_adaptive_rep${repeat_tag}"
            ;;
        adaptive_400001_400000)
            POINT_EPOCH_A=400001
            POINT_EPOCH_B=400000
            POINT_TAG="fig11spec_adaptive_400001_400000_rep${repeat_tag}"
            ;;
        *) ae_die "internal unsupported method: $method" ;;
    esac
    POINT_RUN_DIR="${out_base}/${threshold}_${POINT_EPOCH_A}_${POINT_EPOCH_B}_1_${benchmark}_${POINT_MODE}_${POINT_TAG}"
    POINT_LOG="${POINT_RUN_DIR}/${benchmark}.log"
}

spec_figure_log_valid() {
    local log_file="$1"
    local count
    [[ -s "$log_file" ]] || return 1
    grep -Fxq 'Run Complete' "$log_file" || return 1
    count="$(grep -Ec ';[[:space:]]*[+]?[0-9]+([.][0-9]*)?([eE][+-]?[0-9]+)?[[:space:]]+total seconds[[:space:]]+elapsed[[:space:]]*$' "$log_file" || true)"
    (( count >= 1 ))
}

point_valid() {
    spec_figure_log_valid "$POINT_LOG" || return 1
    ae_runtime_summary_valid "$POINT_RUN_DIR" || return 1
    grep -Fqx \
        "mode=${POINT_MODE} spec=${benchmark} copies=${CHMU_SPEC_COPIES}" \
        "${POINT_RUN_DIR}/runtime_summary.txt" || return 1
    if [[ "$POINT_METHOD" == adaptive_400000_400001 ||
          "$POINT_METHOD" == adaptive_400001_400000 ]]; then
        [[ "$(sha256sum "$model_cfg" | awk '{print $1}')" == "$model_cfg_sha256" ]] || \
            return 1
        ae_adaptive_manager_log_valid "$POINT_RUN_DIR" "$model_cfg" \
            "$POINT_EPOCH_A" "$POINT_EPOCH_B"
    fi
}

printf '%s\n' 'order,repeat,method,label,log_path' > "$manifest"
for method_index in "${!methods[@]}"; do
    order=$((method_index + 1))
    method="${methods[$method_index]}"
    label="${labels[$method_index]}"
    for repeat in 1 2 3 4 5; do
        set_point "$method" "$repeat"
        relative_log="${POINT_LOG#${result_dir}/}"
        printf '%s,%s,%s,%s,%s\n' \
            "$order" "$repeat" "$method" "$label" "$relative_log" >> "$manifest"
    done
done

run_point() {
    local order="$1"
    local repeat="$2"
    local method="$3"
    local label="$4"
    local total_points="${#methods[@]}"
    local extra_env=()

    POINT_EXECUTED=0
    set_point "$method" "$repeat"
    if (( skip_benchmark == 1 )); then
        point_valid || \
            ae_die "canonical SPEC run is missing, incomplete, or did not load the requested adaptive cfg: $POINT_RUN_DIR"
        return 0
    fi
    if (( resume == 1 )) && point_valid; then
        printf '[method %d/%d, repeat %d/5] reuse valid %s\n' \
            "$order" "$total_points" "$repeat" "$POINT_LOG"
        return 0
    fi

    if [[ -e "$POINT_RUN_DIR" || -e "${POINT_RUN_DIR}.log" ]]; then
        ae_confirm "$auto_yes" "[method ${order}/${total_points}, repeat ${repeat}/5] Rerun ${label}; move canonical output to .bakN?" || {
            printf 'Stopped. Rerun with --resume to continue without repeating valid points.\n'
            exit 0
        }
    else
        ae_confirm "$auto_yes" "[method ${order}/${total_points}, repeat ${repeat}/5] Run ${label}?" || {
            printf 'Stopped. Rerun with --resume to continue.\n'
            exit 0
        }
    fi

    case "$method" in
        local)
            extra_env=(
                SRC_NODE="$BUFFER_NODE" DST_NODE="$BUFFER_NODE"
                BASELINE_START_MEMS="$BUFFER_NODE" BASELINE_MEMS="$BUFFER_NODE"
                BASELINE_MEM_POLICY=membind BASELINE_EXPAND_DELAY_SEC=2
                CHMU_MODEL_PATH=
            )
            ;;
        cxl)
            extra_env=(
                SRC_NODE="$CXL_NODE" DST_NODE="$CXL_NODE"
                BASELINE_START_MEMS="$CXL_NODE" BASELINE_MEMS="$CXL_NODE"
                BASELINE_MEM_POLICY=membind BASELINE_EXPAND_DELAY_SEC=2
                CHMU_MODEL_PATH=
            )
            ;;
        cache|cms)
            extra_env=(SRC_NODE="$CXL_NODE" DST_NODE="$BUFFER_NODE" CHMU_MODEL_PATH=)
            ;;
        adaptive_400000_400001|adaptive_400001_400000)
            extra_env=(
                SRC_NODE="$CXL_NODE" DST_NODE="$BUFFER_NODE"
                CHMU_MODEL_PATH="$model_cfg"
                CHMU_ALLOW_PREDICTOR_FALLBACK=0
                MIGRATION_PREDICTOR_INTERVAL_MS=10
            )
            ;;
    esac

    ae_run_with_arc_lock_retry \
        "$FIG11_LOCK_RETRY_INTERVAL_SEC" "$FIG11_LOCK_RETRY_TIMEOUT_SEC" \
        ae_run_spec_point "$SW_DIR" "$out_base" "$threshold" \
        "$POINT_EPOCH_A" "$POINT_EPOCH_B" "$benchmark" \
        "$POINT_MODE" "$POINT_TAG" "${extra_env[@]}"
    point_valid || \
        ae_die "runner returned success but SPEC output validation failed: $POINT_RUN_DIR"
    POINT_EXECUTED=1
}

method_selected() {
    local method="$1"
    case "$selected_method" in
        all) return 0 ;;
        adaptive)
            [[ "$method" == adaptive_400000_400001 ||
               "$method" == adaptive_400001_400000 ]]
            ;;
        *) [[ "$method" == "$selected_method" ]] ;;
    esac
}

if [[ "$selected_method" == all ]]; then
    selected_unit_total=$((5 * ${#methods[@]}))
elif [[ "$selected_method" == adaptive ]]; then
    selected_unit_total=10
else
    selected_unit_total=5
fi
selected_unit_index=0
for repeat in 1 2 3 4 5; do
    for method_index in "${!methods[@]}"; do
        if ! method_selected "${methods[$method_index]}"; then
            continue
        fi
        selected_unit_index=$((selected_unit_index + 1))
        run_point "$((method_index + 1))" "$repeat" \
            "${methods[$method_index]}" "${labels[$method_index]}"
        if (( POINT_EXECUTED == 1 && \
              selected_unit_index < selected_unit_total && \
              FIG11_CASE_INTERVAL_SEC > 0 )); then
            printf '[interval] Waiting %s seconds before the next optional SPEC canonical unit.\n' \
                "$FIG11_CASE_INTERVAL_SEC"
            sleep "$FIG11_CASE_INTERVAL_SEC"
        fi
    done
done

full_sweep_valid() {
    local method
    local repeat
    for method in "${methods[@]}"; do
        for repeat in 1 2 3 4 5; do
            set_point "$method" "$repeat"
            point_valid || return 1
        done
    done
}

if [[ "$selected_method" != all ]] && ! full_sweep_valid; then
    printf '\nCase %s completed. Other canonical cases are not complete yet.\n' \
        "$selected_method"
    printf 'Run the remaining cases, then process the full sweep with --skip-benchmark.\n'
    exit 0
fi

if (( skip_benchmark == 1 )); then
    printf '[1/3] Benchmark skipped; all canonical SPEC logs and summaries validated.\n'
else
    printf '[1/3] All optional SPEC invocations completed or were reused.\n'
fi

printf '[2/3] Select final total-seconds records, compute candidate geometric means, and select the faster adaptive direction.\n'
python3 "${SCRIPT_DIR}/collect_spec_results.py" \
    --manifest "$manifest" \
    --summary-output "$summary_csv" \
    --samples-output "$samples_csv"

plot_status=generated
if (( skip_plot == 1 )); then
    plot_status=skipped_by_request
    printf '[3/3] Plot skipped by --skip-plot.\n'
elif ! python3 -c 'import matplotlib' >/dev/null 2>&1; then
    plot_status=skipped_matplotlib_unavailable
    printf 'WARNING: CSV collection completed, but Matplotlib is unavailable or incompatible; plot skipped.\n' >&2
    printf 'Rerun with --skip-benchmark later in a working plotting environment.\n' >&2
else
    printf '[3/3] Plot normalized performance.\n'
    python3 "${SW_DIR}/fig11/plot_figure11.py" \
        --input "$summary_csv" \
        --output-prefix "$plot_prefix" \
        --title "Optional SPEC: ${display_name}, threshold ${threshold}"
fi

{
    printf 'experiment=figure11_optional_spec\n'
    printf 'suite=spec\nworkload=%s\ndisplay_name=%s\nthreshold=%s\n' \
        "$workload_key" "$display_name" "$threshold"
    printf 'required_pof=SPL1\n'
    if (( skip_benchmark == 1 )); then
        printf 'pof_confirmation=not_requested_processing_only\n'
    else
        printf 'pof_confirmation=reviewer_confirmed_before_run\n'
    fi
    printf 'copies=%s\nrepetitions_per_fixed_method=5\nadaptive_repetitions_per_direction=5\n' "$CHMU_SPEC_COPIES"
    printf 'selected_runtime=final_anchored_total_seconds_elapsed_per_invocation\n'
    printf 'selected_samples_per_method=5\n'
    printf 'baseline=cxl_only_no_migration\n'
    printf 'normalized_performance=cxl_geomean_seconds/method_geomean_seconds\n'
    printf 'adaptive_candidate_directions=400000/400001,400001/400000\n'
    printf 'adaptive_forward_epoch_a=400000\nadaptive_forward_epoch_b=400001\n'
    printf 'adaptive_reverse_epoch_a=400001\nadaptive_reverse_epoch_b=400000\n'
    printf 'adaptive_selection=lower_5_sample_geomean_seconds\npredictor_interval_ms=10\n'
    printf 'adaptive_cfg_source=%s\n' "$pretrained_model_cfg"
    printf 'adaptive_cfg_snapshot=%s\n' "$model_cfg"
    printf 'adaptive_cfg_sha256=%s\n' "$model_cfg_sha256"
    printf 'local_included=%s\n' "$include_local"
    printf 'plot_status=%s\n' "$plot_status"
    printf 'completed_at=%s\n' "$(TZ=America/Chicago date --iso-8601=seconds)"
} > "$metadata_file"

printf '\nOptional SPEC outputs\n'
printf '  metadata : %s\n' "$metadata_file"
printf '  manifest : %s\n' "$manifest"
printf '  samples  : %s\n' "$samples_csv"
printf '  results  : %s\n' "$summary_csv"
printf '  plot status: %s\n' "$plot_status"
if [[ "$plot_status" == generated ]]; then
    printf '  plot     : %s.png\n' "$plot_prefix"
    printf '  plot     : %s.pdf\n' "$plot_prefix"
fi
