#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

if (( $# > 0 )) && [[ "$1" == -h || "$1" == --help ]]; then
    cat <<'EOF'
Usage:
  run_all_primary_th16.sh [options]

Run bc_tw, bfs_tw, and pr_tw sequentially at threshold 16 with automatic
confirmations. CSV results are collected and plotting is deferred. Options
such as --resume are passed to every workload. Newly executed canonical units,
including the boundary between workloads, are separated by 30 seconds by
default. Set FIG11_CASE_INTERVAL_SEC to override the interval.
EOF
    exit 0
fi

FIG11_CASE_INTERVAL_SEC="${FIG11_CASE_INTERVAL_SEC:-30}"
[[ "$FIG11_CASE_INTERVAL_SEC" =~ ^[0-9]+$ ]] || {
    printf 'ERROR: FIG11_CASE_INTERVAL_SEC must be a non-negative integer\n' >&2
    exit 1
}

primary_workloads=(bc_tw bfs_tw pr_tw)
for workload_index in "${!primary_workloads[@]}"; do
    workload="${primary_workloads[$workload_index]}"
    final_execution_marker="$(mktemp "${TMPDIR:-/tmp}/ae4-fig11-final-execution.XXXXXX")"
    rm -f -- "$final_execution_marker"
    printf '\n===== Figure 11 primary workload: %s =====\n' "$workload"
    if FIG11_FINAL_EXECUTION_MARKER="$final_execution_marker" \
       bash "${SCRIPT_DIR}/run_fig11_all_yes.sh" "$workload" \
           "$@" --threshold 16; then
        :
    else
        runner_rc=$?
        rm -f -- "$final_execution_marker"
        exit "$runner_rc"
    fi
    if [[ -e "$final_execution_marker" ]] && \
       (( workload_index + 1 < ${#primary_workloads[@]} && \
          FIG11_CASE_INTERVAL_SEC > 0 )); then
        printf '[interval] Waiting %s seconds before the next Figure 11 workload.\n' \
            "$FIG11_CASE_INTERVAL_SEC"
        sleep "$FIG11_CASE_INTERVAL_SEC"
    fi
    rm -f -- "$final_execution_marker"
done
