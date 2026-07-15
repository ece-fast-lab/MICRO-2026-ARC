#!/usr/bin/env bash

set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

if (( $# != 2 )); then
    echo "Usage: $0 <baseline|mig|anb|damon> <threshold>" >&2
    exit 2
fi

mode="$1"
threshold="$2"

case "${mode}" in
    baseline|mig|anb|damon) ;;
    *) echo "ERROR: invalid benchmark mode: ${mode}" >&2; exit 2 ;;
esac
require_unsigned_value "${threshold}"
require_mmio_access
enable_pcie_memory_space

echo "Disabling CHMU before queue cleanup"
write_csr32 0x40 0
write_csr64 0x48 0

echo "Resetting stale CHMU PFN queue entries"
reset_pfn_queue

if [[ "${mode}" == mig ]]; then
    bash "${SCRIPT_DIR}/chmu_offset_set.sh"
    bash "${SCRIPT_DIR}/chmu_threshold_set.sh" "${threshold}"
    echo "CHMU is configured but remains disabled until migration_manager is ready"
else
    echo "CHMU remains disabled for ${mode} mode"
fi
