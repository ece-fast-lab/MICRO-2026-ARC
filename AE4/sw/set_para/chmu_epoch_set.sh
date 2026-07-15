#!/usr/bin/env bash

set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

if [[ $# -ne 1 ]]; then
    echo "Usage: $0 <epoch-cycles>" >&2
    exit 1
fi

require_unsigned_value "$1"
require_mmio_access
enable_pcie_memory_space

echo "Setting CHMU epoch cycles (CSR 0x40) to $1"
write_csr32 0x40 "$1"
read_csr64 0x40
