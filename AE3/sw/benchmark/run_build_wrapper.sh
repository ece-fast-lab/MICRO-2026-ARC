#!/usr/bin/env bash

set -euo pipefail

if (( $# < 2 )); then
    echo "ERROR: this helper must be called by a build_option_th* wrapper" >&2
    exit 2
fi

BUILD_DIR="$(cd -- "$1" && pwd)"
WRAPPER_NAME="$2"
shift 2

SW_DIR="$(cd -- "${BUILD_DIR}/.." && pwd)"
BUILD_NAME="${BUILD_DIR##*/}"
THRESHOLD="${BUILD_NAME#build_option_th}"

case "${BUILD_NAME}" in
    build_option_th16|build_option_th32|build_option_th64|build_option_th96) ;;
    *)
        echo "ERROR: wrapper directory must be build_option_th16, th32, th64, or th96" >&2
        exit 1
        ;;
esac

export MIGRATION_MANAGER_DIR="${BUILD_DIR}"
export MIGRATION_MAX_MIGRATED_PFNS="${MIGRATION_MAX_MIGRATED_PFNS:-65536}"
export MIGRATION_CPU="${MIGRATION_CPU:-20}"
export MIGRATION_RECLAIM_DISABLE_AFTER_SEC="${MIGRATION_RECLAIM_DISABLE_AFTER_SEC:-1000}"
export WL_CPUS="${WL_CPUS:-0-7}"
export LOCAL_FREE_LOW_MB="${LOCAL_FREE_LOW_MB:-4}"
export RECLAIM_AMOUNT_MB="${RECLAIM_AMOUNT_MB:-2}"
export RECLAIM_CHECK_SEC="${RECLAIM_CHECK_SEC:-1}"
export RECLAIM_COOLDOWN_SEC="${RECLAIM_COOLDOWN_SEC:-1}"

POLL_MS="${CHMU_POLL_MS:-1}"

run_gapbs() {
    local epoch_a="$1"
    local epoch_b="$2"
    shift 2

    if (( $# != 2 )); then
        echo "Usage: ${BUILD_DIR}/${WRAPPER_NAME} <benchmark> <db>" >&2
        echo "  benchmark: bc | bfs | cc | pr" >&2
        echo "  db: web | twitter" >&2
        exit 2
    fi

    bash "${SW_DIR}/benchmark/run_gapbs.sh" \
        "${THRESHOLD}" "${epoch_a}" "${epoch_b}" "${POLL_MS}" \
        "$1" "$2" mig
}

case "${WRAPPER_NAME}" in
    run_test_indv_gap)
        run_gapbs 400000 400000 "$@"
        run_gapbs 400001 400001 "$@"
        run_gapbs \
            "${CHMU_MODE0_EPOCH:-400000}" \
            "${CHMU_MODE1_EPOCH:-400001}" \
            "$@"
        ;;
    run_test_indv_gap_400000_400000)
        run_gapbs 400000 400000 "$@"
        ;;
    run_test_indv_gap_400001_400001)
        run_gapbs 400001 400001 "$@"
        ;;
    run_test_indv_gap_400000_400001)
        run_gapbs \
            "${CHMU_MODE0_EPOCH:-400000}" \
            "${CHMU_MODE1_EPOCH:-400001}" \
            "$@"
        ;;
    run_test_indv_spec_400000_400001)
        if (( $# != 1 )); then
            echo "Usage: ${BUILD_DIR}/${WRAPPER_NAME} <spec-benchmark>" >&2
            echo "  example: ${BUILD_DIR}/${WRAPPER_NAME} 502" >&2
            exit 2
        fi
        exec bash "${SW_DIR}/benchmark/run_spec.sh" \
            "${THRESHOLD}" \
            "${CHMU_MODE0_EPOCH:-400000}" \
            "${CHMU_MODE1_EPOCH:-400001}" \
            "${POLL_MS}" "$1" "${CHMU_SPEC_COPIES:-8}" mig
        ;;
    *)
        echo "ERROR: unsupported build wrapper: ${WRAPPER_NAME}" >&2
        exit 2
        ;;
esac
