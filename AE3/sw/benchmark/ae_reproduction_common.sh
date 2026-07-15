#!/usr/bin/env bash

# Shared, source-only helpers for the AE3 Figure 3/Figure 6/Appendix wrappers.

ae_die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

ae_confirm() {
    local auto_yes="$1"
    local prompt="$2"
    local answer

    if [[ "$auto_yes" == 1 ]]; then
        printf '%s [automatic yes]\n' "$prompt"
        return 0
    fi
    [[ -t 0 ]] || ae_die "interactive confirmation requires a terminal; rerun with --yes"
    read -r -p "${prompt} [y/N] " answer || return 1
    case "${answer,,}" in
        y|yes) return 0 ;;
        *) return 1 ;;
    esac
}

ae_load_platform() {
    local artifact_dir="$1"
    local platform_file="${PLATFORM_CONFIG_FILE:-${artifact_dir}/set_default/generated/platform.env}"

    [[ -r "$platform_file" ]] || \
        ae_die "platform configuration is missing; run set_default/setup_default.sh all first"
    # shellcheck source=/dev/null
    source "$platform_file"
    [[ -n "${CXL_NODE:-}" && -n "${BUFFER_NODE:-}" ]] || \
        ae_die "CXL_NODE/BUFFER_NODE are missing from ${platform_file}"
    export CXL_NODE BUFFER_NODE
}

ae_runner_env() {
    AE_RUNNER_ENV=(
        ENABLE_DEBUG_MONITOR=1
        DBG_INTERVAL_SEC=1
        PHASE1_SEC=10
        MIGRATION_MAX_MIGRATED_PFNS=65536
        MIGRATION_CPU=20
        MIGRATION_RECLAIM_DISABLE_AFTER_SEC=1000
        WL_CPUS=0-7
        LOCAL_FREE_LOW_MB=4
        RECLAIM_AMOUNT_MB=2
        RECLAIM_CHECK_SEC=1
        RECLAIM_COOLDOWN_SEC=1
        OMP_THREADS=8
        DAMON_ALSO_ENABLE_ANB=0
    )
}

ae_gap_log_valid() {
    local log_file="$1"
    local count
    [[ -s "$log_file" ]] || return 1
    count="$(grep -Ec '^Trial Time:[[:space:]]+[0-9]+([.][0-9]+)?[[:space:]]*$' "$log_file" || true)"
    [[ "$count" == 10 ]]
}

ae_spec_log_valid() {
    local log_file="$1"
    local count
    [[ -s "$log_file" ]] || return 1
    grep -Fq 'Run Complete' "$log_file" || return 1
    count="$(grep -Ec ';[[:space:]]*[0-9]+([.][0-9]+)?[[:space:]]+total seconds[[:space:]]+elapsed[[:space:]]*$' "$log_file" || true)"
    [[ "$count" == 1 ]]
}

ae_runtime_summary_valid() {
    local run_dir="$1"
    local summary="${run_dir}/runtime_summary.txt"

    [[ -s "$summary" ]] || return 1
    grep -Eq '^WORKLOAD_PID=[^[:space:]]+[[:space:]]+rc=0$' "$summary" || return 1
    grep -Eq '^MIGRATION_MANAGER_PID=[^[:space:]]+[[:space:]]+rc=0[[:space:]]+failed=0$' "$summary" || return 1
    grep -Fxq 'BACKGROUND_CONTROL_FAILED=0' "$summary" || return 1
    grep -Fxq 'TRACKER_DISABLE_FAILED=0' "$summary" || return 1
}

ae_gap_run_valid() {
    local run_dir="$1"
    local workload_log="$2"
    ae_gap_log_valid "$workload_log" && ae_runtime_summary_valid "$run_dir"
}

ae_spec_run_valid() {
    local run_dir="$1"
    local workload_log="$2"
    ae_spec_log_valid "$workload_log" && ae_runtime_summary_valid "$run_dir"
}

ae_run_gapbs_point() {
    local sw_dir="$1"
    local out_base="$2"
    local threshold="$3"
    local epoch="$4"
    local benchmark="$5"
    local database="$6"
    local mode="$7"
    local tag="$8"
    shift 8

    env \
        "${AE_RUNNER_ENV[@]}" \
        "$@" \
        MIGRATION_MANAGER_DIR="${sw_dir}/build_option_th${threshold}" \
        OUT_BASE_DIR="$out_base" \
        bash "${sw_dir}/benchmark/run_gapbs.sh" \
        "$threshold" "$epoch" "$epoch" 1 "$benchmark" "$database" "$mode" "$tag"
}

ae_run_spec_point() {
    local sw_dir="$1"
    local out_base="$2"
    local threshold="$3"
    local epoch="$4"
    local spec="$5"
    local mode="$6"
    local tag="$7"
    shift 7

    env \
        "${AE_RUNNER_ENV[@]}" \
        "$@" \
        MIGRATION_MANAGER_DIR="${sw_dir}/build_option_th${threshold}" \
        OUT_BASE_DIR="$out_base" \
        bash "${sw_dir}/benchmark/run_spec.sh" \
        "$threshold" "$epoch" "$epoch" 1 "$spec" "${CHMU_SPEC_COPIES:-8}" "$mode" "$tag"
}
