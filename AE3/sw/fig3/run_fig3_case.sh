#!/usr/bin/env bash

set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

usage() {
    cat <<'EOF'
Usage:
  run_fig3_case.sh <workload> <case> [options]

GAPBS workload selectors:
  bc_tw, bfs_tw, cc_tw, pr_tw, bc_web, bfs_web, cc_web, pr_web

Cases:
  all, baseline, anb, damon,
  cache16, cache32, cache64, cache96,
  cms16, cms32, cms64, cms96

Options are forwarded to run_figure3.sh. Common choices are --yes and --resume.
This wrapper runs only the selected canonical case and does not plot.
EOF
}

if (( $# == 0 )) || [[ "${1:-}" == -h || "${1:-}" == --help ]]; then
    usage
    exit 0
fi
(( $# >= 2 )) || { usage >&2; exit 2; }

workload="$1"
case_name="${2,,}"
shift 2
case "$case_name" in
    all|baseline|anb|damon|cache16|cache32|cache64|cache96|cms16|cms32|cms64|cms96) ;;
    *)
        printf 'ERROR: invalid Figure 3 case: %s\n' "$case_name" >&2
        usage >&2
        exit 2
        ;;
esac

exec bash "${SCRIPT_DIR}/run_fig3_gapbs.sh" \
    "$workload" --case "$case_name" --skip-plot "$@"
