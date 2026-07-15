#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

if (( $# == 0 )) || [[ "$1" == -h || "$1" == --help ]]; then
    cat <<'EOF'
Usage:
  plot_fig11.sh <bc_tw|bfs_tw|pr_tw|cc_tw|pr_web> [options]

Validate all existing canonical runs, regenerate the selected-sample and
summary CSV files, and plot Figure 11 without touching benchmark hardware.
Options such as --threshold and --include-local are passed through.
EOF
    (( $# > 0 )) && exit 0
    exit 2
fi

workload="$1"
shift

for argument in "$@"; do
    case "$argument" in
        --resume|--skip-benchmark|--skip-plot|--method|--case)
            printf 'ERROR: %s is controlled by plot_fig11.sh\n' "$argument" >&2
            exit 2
            ;;
    esac
done

command -v python3 >/dev/null 2>&1 || {
    printf 'ERROR: python3 is required for Figure 11 plotting.\n' >&2
    exit 1
}
if ! python3 -c 'import matplotlib' >/dev/null 2>&1; then
    cat >&2 <<'EOF'
ERROR: Matplotlib is unavailable or incompatible in this Python environment.
Use the documented system-package environment:
  env PYTHONNOUSERSITE=1 PYTHONPATH=/usr/lib/python3/dist-packages \
    bash sw/fig11/plot_fig11.sh <workload> --threshold 16
or activate the plotting-only virtual environment first.
EOF
    exit 1
fi

exec bash "${SCRIPT_DIR}/run_figure11.sh" "$workload" \
    "$@" --method all --skip-benchmark --yes
