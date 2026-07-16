#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

if (( $# == 0 )) || [[ "$1" == -h || "$1" == --help ]]; then
    cat <<'EOF'
Usage:
  run_fig11_all_yes.sh <bc_tw|bfs_tw|pr_tw|cc_tw|pr_web> [options]

Run the three fixed Figure 11 methods plus both adaptive epoch directions with
automatic confirmations and collect CSV results without plotting. The result
collector reports the faster complete adaptive direction as one Adaptive bar.
Options such as --threshold and --resume are passed to run_figure11.sh. Newly
executed canonical units are separated by 30 seconds by default. Set
FIG11_CASE_INTERVAL_SEC to override that interval.

If the shared ARC host lock is temporarily busy, only that runner-marked lock
failure is retried. Configure the bounded retry with
FIG11_LOCK_RETRY_INTERVAL_SEC and FIG11_LOCK_RETRY_TIMEOUT_SEC.
EOF
    (( $# > 0 )) && exit 0
    exit 2
fi

workload="$1"
shift
exec bash "${SCRIPT_DIR}/run_figure11.sh" "$workload" \
    "$@" --method all --yes --skip-plot
