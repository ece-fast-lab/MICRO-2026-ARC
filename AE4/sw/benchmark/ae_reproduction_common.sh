#!/usr/bin/env bash

# Shared, source-only helpers for the AE4 Figure 11 and optional training flows.

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

ae_validate_perf_binary() {
    local perf_bin="$1"
    local version_output

    [[ "$perf_bin" == /* && -x "$perf_bin" ]] || \
        ae_die "AE4 adaptive perf must be an executable absolute path: ${perf_bin:-unset}"
    if ! version_output="$("$perf_bin" --version 2>&1)"; then
        printf 'perf output: %s\n' "${version_output:-<empty>}" >&2
        ae_die "AE4 adaptive perf cannot run: $perf_bin. Set CHMU_PERF_BIN to a real tools/perf/perf executable; /usr/bin/perf is an unusable dispatcher for the custom SPR1 kernel"
    fi
    printf '  adaptive perf  : %s (%s)\n' "$perf_bin" "${version_output//$'\n'/ }"
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
        ENABLE_DEBUG_MONITOR=0
        MIGRATION_MAX_MIGRATED_PFNS=65536
        MIGRATION_CPU=20
        MIGRATION_RECLAIM_DISABLE_AFTER_SEC=1000
        MIGRATION_PREDICTOR_INTERVAL_MS=10
        WL_CPUS=0-7
        LOCAL_FREE_LOW_MB=4
        RECLAIM_AMOUNT_MB=2
        RECLAIM_CHECK_SEC=1
        RECLAIM_COOLDOWN_SEC=1
        OMP_THREADS=8
        CHMU_ALLOW_PREDICTOR_FALLBACK=0
    )
}

ae_validate_model_cfg() {
    local cfg="$1"
    local expected_key="$2"
    local field
    local count
    local fields=(
        bw_scale ipc_scale mpki_scale llc_mpki_scale mem_bound_scale
        queue_scale dup_rate_scale max_dup_scale dtlb_mpki_scale bias
        score_margin consecutive_votes_required
        consecutive_votes_required_weak
    )

    [[ "$cfg" == /* ]] || ae_die "model cfg must use an absolute path: $cfg"
    [[ -r "$cfg" ]] || ae_die "model cfg is not readable: $cfg"
    count="$(grep -Ec "^key=${expected_key}$" "$cfg" || true)"
    [[ "$count" == 1 ]] || \
        ae_die "model cfg must contain exactly one key=${expected_key}: $cfg"
    for field in "${fields[@]}"; do
        count="$(grep -Ec "^${field}=[^[:space:]]+$" "$cfg" || true)"
        [[ "$count" == 1 ]] || \
            ae_die "model cfg must contain exactly one ${field}= value: $cfg"
    done
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

ae_adaptive_manager_log_valid() {
    local run_dir="$1"
    local cfg="$2"
    local epoch_a="$3"
    local epoch_b="$4"
    local manager_log="${run_dir}/migration_manager.log"

    [[ -s "$manager_log" ]] || return 1
    grep -Fq "[ml-predict] loaded model override from ${cfg}" "$manager_log" || return 1
    grep -Fq "[mode-switch] ML policy active: mode0(epoch=${epoch_a}) vs mode1(epoch=${epoch_b})" \
        "$manager_log"
}

ae_run_with_arc_lock_retry() {
    local retry_interval="$1"
    local retry_timeout="$2"
    shift 2
    local ARC_LOCK_BUSY_MARKER
    local runner_rc
    local waited_sec=0
    local retry_delay

    ARC_LOCK_BUSY_MARKER="$(mktemp "${TMPDIR:-/tmp}/ae4-arc-lock-busy.XXXXXX")" || \
        ae_die "cannot create the temporary runner lock marker"
    rm -f -- "$ARC_LOCK_BUSY_MARKER"
    export ARC_LOCK_BUSY_MARKER

    while true; do
        rm -f -- "$ARC_LOCK_BUSY_MARKER"
        if "$@"; then
            runner_rc=0
        else
            runner_rc=$?
        fi
        if (( runner_rc == 0 )); then
            rm -f -- "$ARC_LOCK_BUSY_MARKER"
            return 0
        fi

        # The benchmark runner creates this private marker only when its
        # nonblocking flock fails. Stderr is not captured, so all diagnostics
        # remain live. Workload, setup, and validation failures never retry.
        if [[ ! -e "$ARC_LOCK_BUSY_MARKER" ]]; then
            rm -f -- "$ARC_LOCK_BUSY_MARKER"
            return "$runner_rc"
        fi
        if (( retry_timeout == 0 )); then
            rm -f -- "$ARC_LOCK_BUSY_MARKER"
            printf 'ERROR: automatic shared-lock retry is disabled; ' >&2
            printf 'rerun with --resume after the other command exits\n' >&2
            return "$runner_rc"
        fi
        if (( waited_sec >= retry_timeout )); then
            rm -f -- "$ARC_LOCK_BUSY_MARKER"
            printf 'ERROR: shared ARC host lock remained busy after %s seconds; ' \
                "$retry_timeout" >&2
            printf 'rerun with --resume after the other command exits\n' >&2
            return "$runner_rc"
        fi

        retry_delay="$retry_interval"
        if (( retry_delay > retry_timeout - waited_sec )); then
            retry_delay=$((retry_timeout - waited_sec))
        fi
        printf '[lock retry] ARC host lock is still busy; preserving completed ' >&2
        printf 'results and retrying this canonical unit in %s seconds ' \
            "$retry_delay" >&2
        printf '(%s/%s seconds waited).\n' "$waited_sec" "$retry_timeout" >&2
        sleep "$retry_delay"
        waited_sec=$((waited_sec + retry_delay))
    done
}

ae_run_gapbs_point() {
    local sw_dir="$1"
    local out_base="$2"
    local threshold="$3"
    local epoch_a="$4"
    local epoch_b="$5"
    local benchmark="$6"
    local database="$7"
    local mode="$8"
    local tag="$9"
    shift 9

    env \
        "${AE_RUNNER_ENV[@]}" \
        "$@" \
        MIGRATION_MANAGER_DIR="${sw_dir}/build_option_th${threshold}" \
        OUT_BASE_DIR="$out_base" \
        bash "${sw_dir}/benchmark/run_gapbs.sh" \
        "$threshold" "$epoch_a" "$epoch_b" 1 \
        "$benchmark" "$database" "$mode" "$tag"
}

ae_run_spec_point() {
    local sw_dir="$1"
    local out_base="$2"
    local threshold="$3"
    local epoch_a="$4"
    local epoch_b="$5"
    local benchmark="$6"
    local mode="$7"
    local tag="$8"
    shift 8

    env \
        "${AE_RUNNER_ENV[@]}" \
        "$@" \
        MIGRATION_MANAGER_DIR="${sw_dir}/build_option_th${threshold}" \
        OUT_BASE_DIR="$out_base" \
        bash "${sw_dir}/benchmark/run_spec.sh" \
        "$threshold" "$epoch_a" "$epoch_b" 1 \
        "$benchmark" "${CHMU_SPEC_COPIES:-8}" "$mode" "$tag"
}
