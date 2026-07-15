#!/usr/bin/env bash

set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

require_mmio_access
enable_pcie_memory_space

echo "CSR 0x40: query/epoch rate"
read_csr64 0x40
echo "CSR 0x48: push rate"
read_csr64 0x48
echo "CSR 0xB0: overflow-buffer head"
read_csr64 0xB0
echo "CSR 0xB8: overflow-buffer valid count"
read_csr64 0xB8
echo "CSR 0xC0: overflow-buffer maximum"
read_csr64 0xC0
