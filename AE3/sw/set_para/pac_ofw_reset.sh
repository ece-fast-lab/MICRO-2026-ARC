#!/usr/bin/env bash

set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

require_mmio_access
enable_pcie_memory_space
write_csr64 0xD0 0x1
sleep 0.1
write_csr64 0xD0 0x0
write_csr64 0xB0 0x0
read_csr64 0xB0
