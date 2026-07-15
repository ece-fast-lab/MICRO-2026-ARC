#!/usr/bin/env bash

set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

usage() {
    cat <<'EOF'
Usage:
  run_fig3_gapbs.sh <bc|bfs|cc|pr> <web|twitter> [options]
  run_fig3_gapbs.sh <bc|bfs|cc|pr>_<tw|web> [options]

Main AE example:  bash sw/fig3/run_fig3_gapbs.sh pr_tw
See run_figure3.sh --help for --case, --yes, --resume,
--skip-benchmark, and --skip-plot.
EOF
}

(( $# > 0 )) || { usage >&2; exit 2; }
selector="${1,,}"
shift

case "$selector" in
    bc_tw|bfs_tw|cc_tw|pr_tw)
        benchmark="${selector%_tw}"; database=twitter ;;
    bc_twitter|bfs_twitter|cc_twitter|pr_twitter)
        benchmark="${selector%_twitter}"; database=twitter ;;
    bc_web|bfs_web|cc_web|pr_web)
        benchmark="${selector%_web}"; database=web ;;
    bc|bfs|cc|pr)
        (( $# > 0 )) || { usage >&2; exit 2; }
        benchmark="$selector"; database="${1,,}"; shift
        case "$database" in web|twitter) ;; *) usage >&2; exit 2 ;; esac
        ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
esac

exec bash "${SCRIPT_DIR}/run_figure3.sh" gapbs "$benchmark" "$database" "$@"
