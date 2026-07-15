#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

if (( $# > 0 )) && [[ "$1" == -h || "$1" == --help ]]; then
    cat <<'EOF'
Usage:
  run_all_primary_th16.sh [options]

Run bc_tw, bfs_tw, and pr_tw sequentially at threshold 16 with automatic
confirmations. CSV results are collected and plotting is deferred. Options
such as --resume are passed to every workload.
EOF
    exit 0
fi

for workload in bc_tw bfs_tw pr_tw; do
    printf '\n===== Figure 11 primary workload: %s =====\n' "$workload"
    bash "${SCRIPT_DIR}/run_fig11_all_yes.sh" "$workload" \
        "$@" --threshold 16
done
