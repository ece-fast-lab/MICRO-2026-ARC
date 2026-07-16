#!/usr/bin/env bash

set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

usage() {
    cat <<'EOF'
Usage:
  run_fig3_all_yes.sh [workload] [options]

Run all eleven GAPBS Figure 3 cases noninteractively and stop after the
validated results CSV. The workload defaults to pr_tw. Newly executed cases
are separated by 30 seconds to let runner cleanup and logging settle.
If that shared lock is still busy, only that transient lock error is retried
automatically for up to 300 seconds; completed cases remain untouched.

Useful option:
  --resume    Reuse every complete canonical case and run only missing or
              incomplete cases.

Set FIG3_CASE_INTERVAL_SEC to override the 30-second interval.
Set FIG3_LOCK_RETRY_INTERVAL_SEC and FIG3_LOCK_RETRY_TIMEOUT_SEC to override
the 10-second retry interval and 300-second per-case retry timeout.

Plot later with plot_fig3.sh from a Matplotlib-capable Python environment.
EOF
}

if [[ "${1:-}" == -h || "${1:-}" == --help ]]; then
    usage
    exit 0
fi

workload=pr_tw
if (( $# > 0 )) && [[ "$1" != -* ]]; then
    workload="$1"
    shift
fi

for argument in "$@"; do
    case "$argument" in
        --skip-benchmark|--case)
            printf 'ERROR: %s is controlled by run_fig3_all_yes.sh\n' "$argument" >&2
            exit 2
            ;;
    esac
done

exec bash "${SCRIPT_DIR}/run_fig3_gapbs.sh" \
    "$workload" all yes --case all --skip-plot "$@"
