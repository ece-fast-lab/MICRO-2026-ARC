#!/usr/bin/env bash

set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

require_platform_value CXL_MEM_START
require_platform_value CHMU_ADDRESS_OFFSET
require_unsigned_value "${CXL_MEM_START}"
require_unsigned_value "${CHMU_ADDRESS_OFFSET}"
require_mmio_access
enable_pcie_memory_space

echo "Setting CXL memory start (CSR 0x50) to ${CXL_MEM_START}"
write_csr64 0x50 "${CXL_MEM_START}"
echo "Setting CHMU host address offset (CSR 0x70) to ${CHMU_ADDRESS_OFFSET}"
write_csr64 0x70 "${CHMU_ADDRESS_OFFSET}"
