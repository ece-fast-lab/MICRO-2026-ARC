#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

usage() {
    cat <<'EOF'
Usage:
  run_fig11_case.sh <workload> <all|cxl|cache|cms|adaptive|local> [options]

Run five canonical repetitions of one Figure 11 method, or the complete sweep
when method is all, without plotting.
Options, including --threshold, --resume, --yes, and --include-local, are passed
to run_figure11.sh. The local case requires --include-local and the documented
memory-map confirmation.
EOF
}

if (( $# == 1 )) && [[ "$1" == -h || "$1" == --help ]]; then
    usage
    exit 0
fi
(( $# >= 2 )) || { usage >&2; exit 2; }

workload="$1"
method="$2"
shift 2
case "$method" in
    all|cxl|cache|cms|adaptive|local) ;;
    *)
        usage >&2
        printf 'ERROR: unsupported Figure 11 method: %s\n' "$method" >&2
        exit 2
        ;;
esac

exec bash "${SCRIPT_DIR}/run_figure11.sh" "$workload" \
    "$@" --method "$method" --skip-plot
