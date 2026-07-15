#!/usr/bin/env bash

set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
exec env FIG4_ENTRYPOINT_NAME="${0##*/}" \
    bash "${SCRIPT_DIR}/../fig4/run_fig4.sh" 16 "$@"
