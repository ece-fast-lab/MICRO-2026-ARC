#!/usr/bin/env bash

SET_PARA_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SW_DIR="$(cd -- "${SET_PARA_DIR}/.." && pwd)"
ARTIFACT_DIR="$(cd -- "${SW_DIR}/.." && pwd)"

DEFAULT_CONFIG_FILE="${DEFAULT_CONFIG_FILE:-${ARTIFACT_DIR}/set_default/config/defaults.env}"
PLATFORM_CONFIG_FILE="${PLATFORM_CONFIG_FILE:-${ARTIFACT_DIR}/set_default/generated/platform.env}"

if [[ -f "${DEFAULT_CONFIG_FILE}" ]]; then
    # shellcheck source=/dev/null
    source "${DEFAULT_CONFIG_FILE}"
fi

if [[ ! -f "${PLATFORM_CONFIG_FILE}" ]]; then
    echo "ERROR: platform configuration not found: ${PLATFORM_CONFIG_FILE}" >&2
    echo "Run: ${ARTIFACT_DIR}/set_default/setup_default.sh detect" >&2
    return 1 2>/dev/null || exit 1
fi

# shellcheck source=/dev/null
source "${PLATFORM_CONFIG_FILE}"

PCIMEM="${PCIMEM:-${SW_DIR}/pcimem/pcimem}"
BAR2_PATH="${BAR2_PATH:-}"
PCIE_BDF="${PCIE_BDF:-}"

if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    SUDO_CMD=()
else
    SUDO_CMD=(sudo)
fi

require_platform_value() {
    local name="$1"
    if [[ -z "${!name:-}" ]]; then
        echo "ERROR: ${name} is missing from ${PLATFORM_CONFIG_FILE}" >&2
        return 1
    fi
}

require_unsigned_value() {
    local value="$1"
    if [[ ! "${value}" =~ ^(0x[0-9a-fA-F]+|[0-9]+)$ ]]; then
        echo "ERROR: expected an unsigned decimal or hexadecimal value, got: ${value}" >&2
        return 1
    fi
}

require_mmio_access() {
    require_platform_value PCIE_BDF
    require_platform_value BAR2_PATH
    if [[ ! -x "${PCIMEM}" ]]; then
        echo "ERROR: pcimem is not built: ${PCIMEM}" >&2
        echo "Run: ${ARTIFACT_DIR}/set_default/setup_default.sh build" >&2
        return 1
    fi
    if [[ ! -e "${BAR2_PATH}" ]]; then
        echo "ERROR: BAR2 resource does not exist: ${BAR2_PATH}" >&2
        return 1
    fi
}

enable_pcie_memory_space() {
    local command_value
    "${SUDO_CMD[@]}" setpci -s "${PCIE_BDF}" COMMAND=0002:0002
    command_value="$("${SUDO_CMD[@]}" setpci -s "${PCIE_BDF}" COMMAND)"
    command_value="${command_value//[[:space:]]/}"
    [[ "${command_value}" =~ ^[[:xdigit:]]{4}$ ]] || {
        echo "ERROR: invalid PCI COMMAND readback: ${command_value}" >&2
        return 1
    }
    (( (16#${command_value} & 2) != 0 )) || {
        echo "ERROR: PCI memory-space enable bit did not latch: ${command_value}" >&2
        return 1
    }
}

write_csr_checked() {
    local offset="$1"
    local access_type="$2"
    local value="$3"
    local output
    local readback_hex
    local expected_dec
    local readback_dec

    require_unsigned_value "${value}"
    if [[ "${value}" == 0x* ]]; then
        expected_dec=$((16#${value#0x}))
    else
        expected_dec=$((10#${value}))
    fi
    if [[ "${access_type}" == w ]] && (( expected_dec > 0xFFFFFFFF )); then
        echo "ERROR: 32-bit CSR value is too large: ${value}" >&2
        return 1
    fi

    if ! output="$("${SUDO_CMD[@]}" "${PCIMEM}" "${BAR2_PATH}" "${offset}" "${access_type}" "${value}" 2>&1)"; then
        printf '%s\n' "${output}" >&2
        return 1
    fi
    printf '%s\n' "${output}"
    readback_hex="$(sed -nE 's/.*readback 0x[[:space:]]*([[:xdigit:]]+).*/\1/p' <<< "${output}" | tail -n 1)"
    [[ -n "${readback_hex}" ]] || {
        echo "ERROR: pcimem did not report a write readback for CSR ${offset}" >&2
        return 1
    }
    readback_dec=$((16#${readback_hex}))
    (( readback_dec == expected_dec )) || {
        echo "ERROR: CSR ${offset} readback 0x${readback_hex} does not match ${value}" >&2
        return 1
    }
}

write_csr64() {
    write_csr_checked "$1" d "$2"
}

write_csr32() {
    write_csr_checked "$1" w "$2"
}

read_csr64() {
    local offset="$1"
    "${SUDO_CMD[@]}" "${PCIMEM}" "${BAR2_PATH}" "${offset}" d
}

read_csr_value64() {
    local offset="$1"
    local output
    local value

    output="$("${SUDO_CMD[@]}" "${PCIMEM}" "${BAR2_PATH}" "${offset}" d 2>&1)" || {
        printf '%s\n' "${output}" >&2
        return 1
    }
    value="$(sed -nE 's/^0x[[:xdigit:]]+: 0x([[:xdigit:]]+).*$/\1/p' <<< "${output}" | tail -n 1)"
    [[ -n "${value}" ]] || {
        printf '%s\n' "${output}" >&2
        echo "ERROR: could not parse CSR ${offset} read value" >&2
        return 1
    }
    printf '0x%s\n' "${value}"
}

reset_pfn_queue() {
    local attempt
    local queue_value
    local queue_hex
    local queue_length=0

    # CSR 0x58 is a command and may self-clear. Verify its effect through the
    # PFN queue length in bits [41:32] of CSR 0x30.
    "${SUDO_CMD[@]}" "${PCIMEM}" "${BAR2_PATH}" 0x58 d 0x1 >/dev/null
    for attempt in {1..20}; do
        queue_value="$(read_csr_value64 0x30)"
        queue_hex="${queue_value#0x}"
        queue_length=$(( (16#${queue_hex} >> 32) & 0x3FF ))
        if (( queue_length == 0 )); then
            return 0
        fi
        sleep 0.01
    done
    echo "ERROR: CHMU PFN queue did not clear (length=${queue_length})" >&2
    return 1
}
