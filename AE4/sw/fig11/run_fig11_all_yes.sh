#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

if (( $# == 0 )) || [[ "$1" == -h || "$1" == --help ]]; then
    cat <<'EOF'
Usage:
  run_fig11_all_yes.sh <bc_tw|bfs_tw|pr_tw|cc_tw|pr_web> [options]

Run all four Figure 11 methods with automatic confirmations and collect CSV
results without plotting. Options such as --threshold and --resume are passed
to run_figure11.sh.
EOF
    (( $# > 0 )) && exit 0
    exit 2
fi

workload="$1"
shift
exec bash "${SCRIPT_DIR}/run_figure11.sh" "$workload" \
    "$@" --method all --yes --skip-plot
