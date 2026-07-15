#!/usr/bin/env bash

set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

usage() {
    cat <<'EOF'
Usage:
  plot_fig3.sh <workload> [options]

Validate all eleven existing canonical GAPBS cases, regenerate the normalized
CSV, and create the Figure 3 PNG/PDF without running benchmark hardware.

Example:
  env PYTHONNOUSERSITE=1 PYTHONPATH=/usr/lib/python3/dist-packages \
    bash sw/fig3/plot_fig3.sh pr_tw
EOF
}

if (( $# == 0 )) || [[ "${1:-}" == -h || "${1:-}" == --help ]]; then
    usage
    exit 0
fi

workload="$1"
shift
for argument in "$@"; do
    case "$argument" in
        --resume|--skip-plot|--case)
            printf 'ERROR: %s is incompatible with processing-only plotting\n' "$argument" >&2
            exit 2
            ;;
    esac
done

command -v python3 >/dev/null 2>&1 || {
    printf 'ERROR: python3 is required for Figure 3 plotting.\n' >&2
    exit 1
}
if ! python3 -c 'import matplotlib' >/dev/null 2>&1; then
    cat >&2 <<'EOF'
ERROR: Matplotlib is unavailable or incompatible in this Python environment.
Use the documented system-package environment:
  env PYTHONNOUSERSITE=1 PYTHONPATH=/usr/lib/python3/dist-packages \
    bash sw/fig3/plot_fig3.sh <workload>
or activate the plotting-only virtual environment first.
EOF
    exit 1
fi

exec bash "${SCRIPT_DIR}/run_fig3_gapbs.sh" \
    "$workload" --case all --skip-benchmark --yes "$@"
