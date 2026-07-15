#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
if (( $# == 0 )) || [[ "${1:-}" == -h || "${1:-}" == --help ]]; then
    exec bash "${SCRIPT_DIR}/run_figure3.sh" --help
fi
exec bash "${SCRIPT_DIR}/run_figure3.sh" spec "$@"
