#!/usr/bin/env bash

set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

if (( $# != 1 )); then
    echo "Usage: $0 <epoch-cycles>" >&2
    exit 2
fi

epoch_cycles="$1"
require_unsigned_value "${epoch_cycles}"
require_unsigned_value "${CHMU_PUSH_RATE}"
require_mmio_access
enable_pcie_memory_space

# Keep tracking disabled while discarding anything accumulated between the
# initial preparation and manager readiness.
write_csr32 0x40 0
write_csr64 0x48 0
reset_pfn_queue

echo "Starting CHMU with epoch ${epoch_cycles} and push rate ${CHMU_PUSH_RATE}"
write_csr32 0x40 "${epoch_cycles}"
write_csr64 0x48 "${CHMU_PUSH_RATE}"
read_csr64 0x40
read_csr64 0x48
