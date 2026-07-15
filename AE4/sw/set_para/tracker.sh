#!/usr/bin/env bash

set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

case "${1:-}" in
    enable)
        query_rate="${CHMU_QUERY_RATE}"
        push_rate="${CHMU_PUSH_RATE}"
        ;;
    disable)
        query_rate=0
        push_rate=0
        ;;
    *)
        echo "Usage: $0 <enable|disable>" >&2
        exit 1
        ;;
esac

require_mmio_access
require_unsigned_value "${query_rate}"
require_unsigned_value "${push_rate}"
enable_pcie_memory_space
write_csr32 0x40 "${query_rate}"
write_csr64 0x48 "${push_rate}"
read_csr64 0x40
read_csr64 0x48
