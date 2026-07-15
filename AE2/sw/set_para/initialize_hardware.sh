#!/usr/bin/env bash

set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

require_mmio_access
for setting_name in \
    CHMU_RANGE_LOWER CHMU_RANGE_UPPER CHMU_USER_BITS \
    CHMU_QUERY_RATE CHMU_PUSH_RATE; do
    require_platform_value "${setting_name}"
    require_unsigned_value "${!setting_name}"
done
enable_pcie_memory_space
bash "${SCRIPT_DIR}/chmu_offset_set.sh"

echo "Setting CHMU address range"
write_csr64 0x78 "${CHMU_RANGE_LOWER}"
write_csr64 0x80 "${CHMU_RANGE_UPPER}"

echo "Setting CHMU user bits"
write_csr64 0x68 "${CHMU_USER_BITS}"

echo "Setting CHMU query and push rates"
write_csr32 0x40 "${CHMU_QUERY_RATE}"
write_csr64 0x48 "${CHMU_PUSH_RATE}"

echo "CHMU hardware defaults initialized"
