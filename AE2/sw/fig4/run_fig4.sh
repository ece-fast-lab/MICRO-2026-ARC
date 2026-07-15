#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SW_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
ARTIFACT_DIR="$(cd -- "${SW_DIR}/.." && pwd)"

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

path_exists() {
    [[ -e "$1" || -L "$1" ]]
}

usage() {
    local entrypoint="${FIG4_ENTRYPOINT_NAME:-run_fig4_th${THRESHOLD:-32}.sh}"
    cat <<EOF
Usage: ${entrypoint} [all yes] [--skip-benchmark] [--yes]

Reproduce one Figure 4 threshold in three steps:
  1. Run SPEC CPU2017 gcc (502), Cache-only epoch 400000, 8 copies.
  2. Convert debug_monitor.log to debug_monitor.log.txt.
  3. Plot Local/CXL memory and migration traffic as PNG and PDF.

Options:
  all yes             Run every selected step without questions.
  -y, --yes           Answer yes to every selected step.
  --all-yes           Alias for --yes.
  --skip-benchmark    Reuse the canonical existing debug_monitor.log; never
                      move or rerun the benchmark output.
  -h, --help          Show this help.

Examples:
  ./${entrypoint}
  ./${entrypoint} all yes
  ./${entrypoint} --skip-benchmark
  ./${entrypoint} --skip-benchmark --yes
EOF
}

if (( $# < 1 )); then
    THRESHOLD=""
    usage >&2
    exit 2
fi

THRESHOLD="$1"
shift
case "$THRESHOLD" in
    16|32|64|96) ;;
    *) die "threshold must be one of: 16, 32, 64, 96" ;;
esac

AUTO_YES=0
SKIP_BENCHMARK=0

if (( $# >= 2 )) && [[ "$1" == "all" && "$2" == "yes" ]]; then
    AUTO_YES=1
    shift 2
fi

while (( $# > 0 )); do
    case "$1" in
        -y|--yes|--all-yes)
            AUTO_YES=1
            ;;
        --skip-benchmark)
            SKIP_BENCHMARK=1
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            usage >&2
            die "unknown option: $1"
            ;;
    esac
    shift
done

BUILD_DIR="${SW_DIR}/build_option_th${THRESHOLD}"
OUT_BASE_DIR="${BUILD_DIR}/output"
RUN_TAG="fig4_gcc_cache"
RUN_NAME="${THRESHOLD}_400000_400000_1_502_mig_${RUN_TAG}"
RUN_DIR="${OUT_BASE_DIR}/${RUN_NAME}"
RUN_LOG="${RUN_DIR}.log"
RAW_LOG="${RUN_DIR}/debug_monitor.log"
CSV_LOG="${RAW_LOG}.txt"
PLOT_PREFIX="${RUN_DIR}/memory_usage_migration_traffic"
CONVERTER_SOURCE="${SCRIPT_DIR}/sum_status_fail_MBs.sh"
PLOT_SOURCE="${SCRIPT_DIR}/plot_memory_migration.py"

confirm_step() {
    local prompt="$1"
    local answer

    if (( AUTO_YES == 1 )); then
        printf '%s [automatic yes]\n' "$prompt"
        return 0
    fi
    [[ -t 0 ]] || die "interactive confirmation requires a terminal; rerun with --yes"
    read -r -p "${prompt} [y/N] " answer || return 1
    case "${answer,,}" in
        y|yes) return 0 ;;
        *) return 1 ;;
    esac
}

processing_preflight() {
    command -v python3 >/dev/null 2>&1 || die "python3 is required"
    python3 -c 'import matplotlib' >/dev/null 2>&1 || \
        die "Python matplotlib is required (for example: python3 -m pip install matplotlib)"
    [[ -r "$CONVERTER_SOURCE" ]] || die "converter is missing: $CONVERTER_SOURCE"
    [[ -r "$PLOT_SOURCE" ]] || die "plot program is missing: $PLOT_SOURCE"
}

benchmark_preflight() {
    local defaults_file="${DEFAULT_CONFIG_FILE:-${ARTIFACT_DIR}/set_default/config/defaults.env}"
    local platform_file="${PLATFORM_CONFIG_FILE:-${ARTIFACT_DIR}/set_default/generated/platform.env}"
    local paths_file="${BENCHMARK_PATHS_FILE:-${SW_DIR}/config/benchmark_paths.env}"
    local actual_hostname

    command -v numastat >/dev/null 2>&1 || die "numastat is required for Figure 4 logging"
    [[ -r "$defaults_file" ]] || die "setup defaults are missing: $defaults_file"
    # shellcheck source=/dev/null
    source "$defaults_file"
    actual_hostname="$(hostname -s)"
    if [[ "$actual_hostname" != "$EXPECTED_HOSTNAME" && "$ALLOW_NON_SPR1" != 1 ]]; then
        die "benchmark execution is restricted to ${EXPECTED_HOSTNAME}; use --skip-benchmark to process an existing log"
    fi
    [[ "$(uname -r)" == "$EXPECTED_KERNEL_RELEASE" ]] || \
        die "running kernel $(uname -r) does not match $EXPECTED_KERNEL_RELEASE"

    [[ -r "$platform_file" ]] || \
        die "platform configuration is missing; run set_default/setup_default.sh all first"
    # shellcheck source=/dev/null
    source "$platform_file"
    [[ "${BUFFER_NODE:-}" == 0 && "${CXL_NODE:-}" == 1 ]] || \
        die "Figure 4 requires BUFFER_NODE=0 (Local) and CXL_NODE=1; detected BUFFER_NODE=${BUFFER_NODE:-unset}, CXL_NODE=${CXL_NODE:-unset}"

    [[ -r "$paths_file" ]] || die "benchmark path configuration is missing: $paths_file"
    # shellcheck source=/dev/null
    source "$paths_file"
    [[ -d "${SPEC_ROOT:-}" ]] || die "SPEC_ROOT is not a directory: ${SPEC_ROOT:-unset}"
    [[ -x "${SPEC_RUNCPU:-}" ]] || die "SPEC_RUNCPU is not executable: ${SPEC_RUNCPU:-unset}"
    [[ -r "${SPEC_CONFIG:-}" ]] || die "SPEC_CONFIG is not readable: ${SPEC_CONFIG:-unset}"
    [[ -x "${BUILD_DIR}/migration_manager" ]] || \
        die "threshold ${THRESHOLD} manager is not built; run set_default/setup_default.sh build"
}

validate_raw_log() {
    [[ -s "$RAW_LOG" ]] || die "raw debug log is missing or empty: $RAW_LOG"
    grep -Eq '^===== \[debug\] periodic @ [0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2} =====$' "$RAW_LOG" || \
        die "raw log has no periodic debug block: $RAW_LOG"
    grep -Eq '^pgmigrate_success[[:space:]]+[0-9]+$' "$RAW_LOG" || \
        die "raw log has no pgmigrate_success counter: $RAW_LOG"
    grep -Fq 'Per-node process memory usage (in MBs)' "$RAW_LOG" || \
        die "raw log has no numastat process table: $RAW_LOG"
    grep -Eq '^[[:space:]]*Total[[:space:]]+[0-9]+[[:space:]]+[0-9]+' "$RAW_LOG" || \
        die "raw log has no numastat Total row: $RAW_LOG"
}

install_processing_tools() {
    cp -- "$CONVERTER_SOURCE" "${RUN_DIR}/sum_status_fail_MBs.sh"
    cp -- "$PLOT_SOURCE" "${RUN_DIR}/plot_memory_migration.py"
    chmod 0755 "${RUN_DIR}/sum_status_fail_MBs.sh" "${RUN_DIR}/plot_memory_migration.py"
}

printf '\nFigure 4 threshold %s configuration\n' "$THRESHOLD"
printf '  benchmark       : SPEC CPU2017 gcc (502), 8 copies\n'
printf '  CHMU mode       : Cache-only, epoch 400000/400000\n'
printf '  threshold/poll  : %s / 1 ms\n' "$THRESHOLD"
printf '  placement       : Node 1 (CXL) -> Node 0 (Local)\n'
printf '  warmup          : 10 s before migration starts\n'
printf '  raw sampling    : 5 s interval, numastat -c base + /proc/vmstat\n'
printf '  output          : %s\n\n' "$RUN_DIR"

processing_preflight

if (( SKIP_BENCHMARK == 1 )); then
    printf '[1/3] Skip benchmark; reuse the canonical result directory.\n'
    [[ -d "$RUN_DIR" && ! -L "$RUN_DIR" ]] || \
        die "canonical result directory does not exist: $RUN_DIR"
    validate_raw_log
else
    benchmark_preflight

    if path_exists "$RUN_DIR" || path_exists "$RUN_LOG"; then
        [[ ! -L "$RUN_DIR" ]] || die "refusing to replace symlinked output directory: $RUN_DIR"
        if ! confirm_step "[1/3] Existing result found. Move it to .bak (or .bak.N) and rerun gcc?"; then
            printf 'Stopped before benchmark. To reuse it, run: %s --skip-benchmark\n' \
                "${FIG4_ENTRYPOINT_NAME:-run_fig4_th${THRESHOLD}.sh}"
            exit 0
        fi
    else
        if ! confirm_step "[1/3] Run gcc and collect debug_monitor.log now?"; then
            printf 'Stopped before benchmark.\n'
            exit 0
        fi
    fi

    env \
        ENABLE_DEBUG_MONITOR=1 \
        DBG_INTERVAL_SEC=5 \
        PHASE1_SEC=10 \
        MIGRATION_START_DELAY_SEC=10 \
        MIGRATION_MANAGER_DIR="$BUILD_DIR" \
        OUT_BASE_DIR="$OUT_BASE_DIR" \
        MIGRATION_MAX_MIGRATED_PFNS=65536 \
        MIGRATION_CPU=20 \
        MIGRATION_RECLAIM_DISABLE_AFTER_SEC=1000 \
        WL_CPUS=0-7 \
        LOCAL_FREE_LOW_MB=4 \
        RECLAIM_AMOUNT_MB=2 \
        RECLAIM_CHECK_SEC=1 \
        RECLAIM_COOLDOWN_SEC=1 \
        RUN_OUTPUT_POLICY=backup \
        bash "${SW_DIR}/benchmark/run_spec.sh" \
            "$THRESHOLD" 400000 400000 1 502 8 mig "$RUN_TAG"

    validate_raw_log
fi

if ! confirm_step "[2/3] Convert debug_monitor.log to debug_monitor.log.txt?"; then
    printf 'Stopped before conversion. Resume with: %s --skip-benchmark\n' \
        "${FIG4_ENTRYPOINT_NAME:-run_fig4_th${THRESHOLD}.sh}"
    exit 0
fi
install_processing_tools
bash "${RUN_DIR}/sum_status_fail_MBs.sh" "$RAW_LOG" "$CSV_LOG"
[[ -s "$CSV_LOG" ]] || die "conversion did not create a nonempty CSV: $CSV_LOG"

if ! confirm_step "[3/3] Plot Local Memory, CXL Memory, and Migration Traffic?"; then
    printf 'Stopped before plotting. CSV is ready: %s\n' "$CSV_LOG"
    exit 0
fi
python3 "${RUN_DIR}/plot_memory_migration.py" \
    --input "$CSV_LOG" \
    --output-prefix "$PLOT_PREFIX" \
    --title "Threshold ${THRESHOLD}"

printf '\nFigure 4 threshold %s completed.\n' "$THRESHOLD"
printf '  raw log : %s\n' "$RAW_LOG"
printf '  CSV     : %s\n' "$CSV_LOG"
printf '  PNG     : %s.png\n' "$PLOT_PREFIX"
printf '  PDF     : %s.pdf\n' "$PLOT_PREFIX"
printf '  code    : %s, %s\n' \
    "${RUN_DIR}/sum_status_fail_MBs.sh" "${RUN_DIR}/plot_memory_migration.py"
