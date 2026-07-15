#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
QUARTUS_BIN="${QUARTUS_BIN:-/fast-lab-share/software/quartus/24.3.1/quartus/bin/quartus_pgm}"
PROGRAMMER_CABLE="${PROGRAMMER_CABLE:-AGI FPGA Development Kit [3-12]}"

if (( $# != 1 )); then
    echo "Usage: $0 <cdf-file>" >&2
    exit 2
fi

CDF_FILE="$1"
if [[ "${CDF_FILE}" != /* ]]; then
    CDF_FILE="${SCRIPT_DIR}/${CDF_FILE}"
fi

[[ -x "${QUARTUS_BIN}" ]] || { echo "ERROR: quartus_pgm not found: ${QUARTUS_BIN}" >&2; exit 1; }
[[ -r "${CDF_FILE}" ]] || { echo "ERROR: CDF file not found: ${CDF_FILE}" >&2; exit 1; }

if (( EUID == 0 )); then
    "${QUARTUS_BIN}" -c "${PROGRAMMER_CABLE}" "${CDF_FILE}"
else
    sudo "${QUARTUS_BIN}" -c "${PROGRAMMER_CABLE}" "${CDF_FILE}"
fi
