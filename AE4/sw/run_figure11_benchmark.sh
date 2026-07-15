#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

usage() {
    cat <<'EOF'
Usage:
  run_figure11_benchmark.sh gapbs <bc_tw|bfs_tw|pr_tw|cc_tw|pr_web> [options]
  run_figure11_benchmark.sh spec  <gcc|mcf|cactuB|cam4|roms> [options]

Dispatch one selectable benchmark to the GAPBS Figure 11 reviewer flow or the
optional SPEC Figure-11-style flow. Runner-specific options are passed through.
EOF
}

if (( $# == 1 )) && [[ "$1" == -h || "$1" == --help ]]; then
    usage
    exit 0
fi
(( $# >= 2 )) || { usage >&2; exit 2; }
suite="$1"
benchmark="$2"
shift 2

case "$suite" in
    gapbs|gap)
        exec bash "${SCRIPT_DIR}/fig11/run_figure11.sh" "$benchmark" "$@"
        ;;
    spec)
        exec bash "${SCRIPT_DIR}/fig11_spec/run_figure11_spec.sh" \
            "$benchmark" "$@"
        ;;
    *)
        usage >&2
        printf 'ERROR: suite must be gapbs or spec, got: %s\n' "$suite" >&2
        exit 2
        ;;
esac
