#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ARTIFACT_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
ARTIFACT_NAME="${ARTIFACT_DIR##*/}"
SW_DIR="${ARTIFACT_DIR}/sw"
DEFAULT_CONFIG_FILE="${DEFAULT_CONFIG_FILE:-${SCRIPT_DIR}/config/defaults.env}"
BENCHMARK_PATHS_FILE="${BENCHMARK_PATHS_FILE:-${SW_DIR}/config/benchmark_paths.env}"
GENERATED_DIR="${SCRIPT_DIR}/generated"
PLATFORM_CONFIG_FILE="${PLATFORM_CONFIG_FILE:-${GENERATED_DIR}/platform.env}"
BUILD_CONFIG_FILE="${BUILD_CONFIG_FILE:-${GENERATED_DIR}/build.env}"
KERNEL_BUILD="${KERNEL_BUILD:-/lib/modules/$(uname -r)/build}"
ARC_LOCK_FILE="${ARC_LOCK_FILE:-/run/lock/micro_2026_arc.lock}"
export DEFAULT_CONFIG_FILE BENCHMARK_PATHS_FILE PLATFORM_CONFIG_FILE BUILD_CONFIG_FILE ARC_LOCK_FILE
PREFLIGHT_COMPLETE=0

# shellcheck source=config/defaults.env
source "${DEFAULT_CONFIG_FILE}"
# shellcheck source=/dev/null
source "${BENCHMARK_PATHS_FILE}"

usage() {
    cat <<'EOF'
Usage: setup_default.sh <command>

Commands:
  check    Verify the SPR1 software and custom-kernel prerequisites.
  detect   Detect the PCI BDF, BAR2 path, CXL NUMA node, and CXL PFNs.
  build    Build pcimem/managers; reuse valid bundled kernel modules.
  apply    Apply system defaults, load modules, and initialize CHMU CSRs.
  all      Run check, detect, build, apply, and status in that order.
  status   Print the generated platform configuration and software status.
  disable  Disable CHMU tracking and unload the artifact kernel modules.

Optional detection overrides:
  PCIE_BDF=0000:40:00.1 CXL_NODE=1 BUFFER_NODE=0 \
    bash set_default/setup_default.sh detect

This script must be run on SPR1. Run it as the reviewer account; it invokes
sudo only for privileged operations.
EOF
}

info() {
    printf '[%s] %s\n' "${ARTIFACT_NAME}" "$*"
}

warn() {
    printf '[%s] WARNING: %s\n' "${ARTIFACT_NAME}" "$*" >&2
}

die() {
    printf '[%s] ERROR: %s\n' "${ARTIFACT_NAME}" "$*" >&2
    exit 1
}

normalize_kernel_bool() {
    case "${1,,}" in
        1|y|yes|true|on)  printf '1\n' ;;
        0|n|no|false|off) printf '0\n' ;;
        *) return 1 ;;
    esac
}

require_target_host() {
    local actual_hostname
    actual_hostname="$(hostname -s)"
    if [[ "${actual_hostname}" != "${EXPECTED_HOSTNAME}" && "${ALLOW_NON_SPR1}" != 1 ]]; then
        die "this command is restricted to ${EXPECTED_HOSTNAME}; current host is ${actual_hostname}. Set ALLOW_NON_SPR1=1 only for an intentional port."
    fi
}

acquire_exclusive_lock() {
    if [[ ! -e "${ARC_LOCK_FILE}" ]]; then
        (umask 000; set -o noclobber; : > "${ARC_LOCK_FILE}") 2>/dev/null || true
    fi
    # Open without O_CREAT/O_TRUNC so a lock first created by another UID also
    # works with Linux protected_regular restrictions in sticky /run/lock.
    exec 9<"${ARC_LOCK_FILE}" || die "cannot open exclusive lock: ${ARC_LOCK_FILE}"
    flock -n 9 || die "another ARC setup or benchmark command is active on this host"
}

run_root() {
    if (( EUID == 0 )); then
        "$@"
    else
        sudo "$@"
    fi
}

write_root_value() {
    local file="$1"
    local value="$2"

    [[ -e "${file}" ]] || die "required kernel setting does not exist: ${file}"
    if (( EUID == 0 )); then
        printf '%s\n' "${value}" > "${file}"
    else
        printf '%s\n' "${value}" | sudo tee "${file}" >/dev/null
    fi
}

cpu_frequency_control_is_active() {
    local governor_file="$1"
    local cpu_dir
    local online_file

    cpu_dir="${governor_file%/cpufreq/scaling_governor}"
    online_file="${cpu_dir}/online"
    # CPU0 normally has no online control file and is always online.
    [[ ! -e "${online_file}" || "$(< "${online_file}")" == 1 ]]
}

require_platform_config() {
    [[ -r "${PLATFORM_CONFIG_FILE}" ]] || \
        die "platform configuration is missing; run '$0 detect' first"
    # shellcheck source=/dev/null
    source "${PLATFORM_CONFIG_FILE}"

    local name
    for name in PCIE_BDF BAR2_PATH CXL_MEM_START CXL_MEM_PFN \
                CXL_MEM_NUM_PFN CXL_NODE BUFFER_NODE; do
        [[ -n "${!name:-}" ]] || die "${name} is missing from ${PLATFORM_CONFIG_FILE}"
    done
}

module_file_matches_running_kernel() {
    local module_file="$1"
    local expected_name="$2"
    local actual_name
    local module_kernel

    [[ -r "${module_file}" ]] || return 1
    actual_name="$(modinfo -F name "${module_file}" 2>/dev/null)" || return 1
    module_kernel="$(modinfo -F vermagic "${module_file}" 2>/dev/null | awk '{print $1}')" || return 1
    [[ "${actual_name}" == "${expected_name}" && "${module_kernel}" == "$(uname -r)" ]]
}

bundled_kernel_modules_are_usable() {
    local page_module="${SW_DIR}/kmod_pgmigrate/page_migrate.ko"
    local overflow_module="${SW_DIR}/kmod_pac_ofw_buf/pac_ofw_buf.ko"
    local page_hash
    local overflow_hash

    [[ "$(uname -r)" == "${BUNDLED_MODULE_KERNEL_RELEASE}" ]] || return 1
    module_file_matches_running_kernel "${page_module}" page_migrate || return 1
    module_file_matches_running_kernel "${overflow_module}" pac_ofw_buf || return 1
    page_hash="$(sha256sum "${page_module}" | awk '{print $1}')"
    overflow_hash="$(sha256sum "${overflow_module}" | awk '{print $1}')"
    [[ "${page_hash}" == "${BUNDLED_PAGE_MODULE_SHA256}" &&
       "${overflow_hash}" == "${BUNDLED_OVERFLOW_MODULE_SHA256}" ]]
}

stamped_kernel_modules_are_usable() {
    local require_platform_match="${1:-0}"
    local page_module="${SW_DIR}/kmod_pgmigrate/page_migrate.ko"
    local overflow_module="${SW_DIR}/kmod_pac_ofw_buf/pac_ofw_buf.ko"
    local page_hash
    local overflow_hash

    [[ -r "${BUILD_CONFIG_FILE}" ]] || return 1
    module_file_matches_running_kernel "${page_module}" page_migrate || return 1
    module_file_matches_running_kernel "${overflow_module}" pac_ofw_buf || return 1
    page_hash="$(sha256sum "${page_module}" | awk '{print $1}')"
    overflow_hash="$(sha256sum "${overflow_module}" | awk '{print $1}')"

    (
        # shellcheck source=/dev/null
        source "${BUILD_CONFIG_FILE}"
        [[ "${BUILT_KERNEL_RELEASE:-}" == "$(uname -r)" &&
           "${BUILT_PAGE_MODULE_SHA256:-}" == "${page_hash}" &&
           "${BUILT_OVERFLOW_MODULE_SHA256:-}" == "${overflow_hash}" ]] || exit 1
        if [[ "${require_platform_match}" == 1 ]]; then
            [[ "${BUILT_PCIE_BDF:-}" == "${PCIE_BDF:-}" &&
               "${BUILT_BAR2_PATH:-}" == "${BAR2_PATH:-}" &&
               "${BUILT_CXL_MEM_START:-}" == "${CXL_MEM_START:-}" &&
               "${BUILT_CXL_MEM_PFN:-}" == "${CXL_MEM_PFN:-}" &&
               "${BUILT_CXL_MEM_NUM_PFN:-}" == "${CXL_MEM_NUM_PFN:-}" &&
               "${BUILT_CXL_NODE:-}" == "${CXL_NODE:-}" &&
               "${BUILT_BUFFER_NODE:-}" == "${BUFFER_NODE:-}" ]]
        fi
    )
}

kernel_modules_are_reusable() {
    local require_platform_match="${1:-0}"
    REUSABLE_MODULE_SOURCE=""

    if bundled_kernel_modules_are_usable; then
        if [[ "${require_platform_match}" == 1 ]] &&
           [[ "${CXL_NODE:-}" != "${BUNDLED_CXL_NODE}" ||
              "${BUFFER_NODE:-}" != "${BUNDLED_BUFFER_NODE}" ]]; then
            return 1
        fi
        REUSABLE_MODULE_SOURCE="bundled-prebuilt"
        return 0
    fi
    if stamped_kernel_modules_are_usable "${require_platform_match}"; then
        REUSABLE_MODULE_SOURCE="existing-build"
        return 0
    fi
    return 1
}

check_requirements() {
    local missing=0
    local command_name
    local required_commands=(
        bash cmake make gcc g++ lspci setpci numactl taskset
        rdmsr wrmsr pqos modprobe modinfo insmod rmmod swapoff swapon
        flock ldconfig sha256sum pgrep pkill readlink mktemp
    )
    local actual_kernel
    local build_kernel
    local cmdline_token
    local controllers
    local governor_file
    local available_governors
    local cpu_dir
    local offline_governor_cpus=""
    local perf_version_output
    local -a required_cmdline=(
        'intel_iommu=on,sm_on'
        'iommu=pt'
        'no5lvl'
        'efi=nosoftreserve'
        "memmap=${REQUIRED_MEMMAP}"
    )

    info "checking commands and kernel-module artifacts"
    if (( EUID != 0 )); then
        required_commands+=(sudo)
    fi

    for command_name in "${required_commands[@]}"; do
        if ! command -v "${command_name}" >/dev/null 2>&1; then
            printf '  MISSING  %s\n' "${command_name}" >&2
            missing=1
        else
            printf '  OK       %s\n' "${command_name}"
        fi
    done

    if [[ "${CHMU_PERF_BIN:-}" != /* || ! -x "${CHMU_PERF_BIN:-}" ]]; then
        warn "AE4 adaptive perf binary is missing or not executable: ${CHMU_PERF_BIN:-unset}"
        warn "set CHMU_PERF_BIN to the real tools/perf/perf executable; do not use the Ubuntu /usr/bin/perf dispatcher"
        missing=1
    elif ! perf_version_output="$("${CHMU_PERF_BIN}" --version 2>&1)"; then
        warn "AE4 adaptive perf binary cannot run: ${CHMU_PERF_BIN}"
        [[ -z "${perf_version_output}" ]] || printf '           %s\n' "${perf_version_output//$'\n'/ }" >&2
        missing=1
    else
        printf '  OK       adaptive perf: %s (%s)\n' \
            "${CHMU_PERF_BIN}" "${perf_version_output//$'\n'/ }"
    fi

    actual_kernel="$(uname -r)"
    if [[ "${actual_kernel}" != "${EXPECTED_KERNEL_RELEASE}" ]]; then
        warn "wrong running kernel: ${actual_kernel} (expected ${EXPECTED_KERNEL_RELEASE})"
        missing=1
    else
        printf '  OK       running kernel: %s\n' "${actual_kernel}"
    fi

    for cmdline_token in "${required_cmdline[@]}"; do
        if ! tr ' ' '\n' < /proc/cmdline | grep -Fxq -- "${cmdline_token}"; then
            warn "required kernel command-line token is missing: ${cmdline_token}"
            missing=1
        else
            printf '  OK       kernel cmdline: %s\n' "${cmdline_token}"
        fi
    done

    if kernel_modules_are_reusable 0; then
        printf '  OK       kernel modules: %s (%s)\n' \
            "${SW_DIR}" "${REUSABLE_MODULE_SOURCE}"
        printf '  SKIP     kernel build tree (valid modules already exist)\n'
    else
        if [[ ! -d "${KERNEL_BUILD}" ]]; then
            warn "matching kernel build directory is missing: ${KERNEL_BUILD}"
            missing=1
        else
            printf '  OK       kernel build: %s\n' "${KERNEL_BUILD}"
            if [[ -r "${KERNEL_BUILD}/include/config/kernel.release" ]]; then
                build_kernel="$(< "${KERNEL_BUILD}/include/config/kernel.release")"
                if [[ "${build_kernel}" != "${actual_kernel}" ]]; then
                    warn "kernel build release ${build_kernel} does not match running kernel ${actual_kernel}"
                    missing=1
                fi
            else
                warn "kernel build release file is missing: ${KERNEL_BUILD}/include/config/kernel.release"
                missing=1
            fi
        fi

        local cxl_header=""
        local header_candidate
        for header_candidate in \
            "${KERNEL_BUILD}/include/linux/cxl_migrate.h" \
            "${KERNEL_BUILD}/source/include/linux/cxl_migrate.h"; do
            if [[ -r "${header_candidate}" ]]; then
                cxl_header="${header_candidate}"
                break
            fi
        done
        if [[ -z "${cxl_header}" ]]; then
            warn "the custom linux/cxl_migrate.h header is missing below ${KERNEL_BUILD}"
            warn "page_migrate requires the SPR1 6.11.0-mig-offload+ kernel tree"
            missing=1
        else
            printf '  OK       custom header: %s\n' "${cxl_header}"
        fi

        if [[ ! -r "${KERNEL_BUILD}/Module.symvers" ]]; then
            warn "kernel Module.symvers is missing: ${KERNEL_BUILD}/Module.symvers"
            missing=1
        else
            local symbol
            for symbol in cxl_pa_migrate reset_cxl_stats print_cxl_stats; do
                if ! grep -qw "${symbol}" "${KERNEL_BUILD}/Module.symvers"; then
                    warn "custom kernel symbol is absent from Module.symvers: ${symbol}"
                    missing=1
                fi
            done
        fi
    fi

    if [[ ! -r /usr/include/numa.h ]]; then
        warn "libnuma development header is missing: /usr/include/numa.h"
        missing=1
    else
        printf '  OK       libnuma development header\n'
    fi
    if [[ "$(ldconfig -p 2>/dev/null)" != *libnuma.so* ]]; then
        warn "libnuma runtime/development linker entry was not found"
        missing=1
    else
        printf '  OK       libnuma linker entry\n'
    fi

    if [[ ! -e /sys/fs/cgroup/cgroup.controllers ]]; then
        warn "cgroup v2 was not detected; benchmark runners require it"
        missing=1
    else
        printf '  OK       cgroup v2\n'
        controllers="$(< /sys/fs/cgroup/cgroup.controllers)"
        for command_name in cpuset memory; do
            if [[ " ${controllers} " != *" ${command_name} "* ]]; then
                warn "cgroup v2 controller is unavailable: ${command_name}"
                missing=1
            fi
        done
    fi

    if ! compgen -G '/sys/devices/system/cpu/cpu*/cpufreq/scaling_governor' >/dev/null; then
        warn "CPU frequency control sysfs entries were not detected"
        missing=1
    else
        printf '  OK       CPU frequency controls\n'
        for governor_file in /sys/devices/system/cpu/cpu[0-9]*/cpufreq/scaling_governor; do
            [[ -e "${governor_file}" ]] || continue
            if ! cpu_frequency_control_is_active "${governor_file}"; then
                cpu_dir="${governor_file%/cpufreq/scaling_governor}"
                offline_governor_cpus+="${offline_governor_cpus:+ }${cpu_dir##*/}"
                continue
            fi
            if [[ ! -r "${governor_file%/*}/scaling_available_governors" ||
                  ! -e "${governor_file%/*}/scaling_setspeed" ]]; then
                warn "incomplete CPU frequency controls below ${governor_file%/*}"
                missing=1
                continue
            fi
            available_governors="$(< "${governor_file%/*}/scaling_available_governors")"
            if [[ " ${available_governors} " != *' userspace '* ]]; then
                warn "userspace governor is unavailable below ${governor_file%/*}"
                missing=1
            fi
        done
        if [[ -n "${offline_governor_cpus}" ]]; then
            printf '  SKIP     inactive CPU frequency controls: %s\n' "${offline_governor_cpus}"
        fi
    fi

    if [[ ! -d /sys/devices/system/cpu/cpu31 ]]; then
        warn "SPR1 CPU topology is incomplete: CPU31 is missing"
        missing=1
    else
        printf '  OK       SPR1 CPUs 0-31 detected\n'
    fi
    if [[ ! -e /sys/kernel/mm/numa/demotion_enabled ]]; then
        warn "NUMA demotion control is missing"
        missing=1
    else
        printf '  OK       NUMA demotion control\n'
    fi

    (( missing == 0 )) || die "preflight failed; install/fix the items marked above"
    PREFLIGHT_COMPLETE=1
    info "preflight passed"
}

normalize_bdf() {
    local bdf="${1,,}"
    if [[ "${bdf}" =~ ^[[:xdigit:]]{2}:[[:xdigit:]]{2}\.[0-7]$ ]]; then
        bdf="0000:${bdf}"
    fi
    [[ "${bdf}" =~ ^[[:xdigit:]]{4}:[[:xdigit:]]{2}:[[:xdigit:]]{2}\.[0-7]$ ]] || \
        die "invalid PCI BDF: ${1}"
    printf '%s\n' "${bdf}"
}

detect_pcie_bdf() {
    local -a candidates=()
    local line

    [[ "${EXPECTED_PCI_ID}" =~ ^[[:xdigit:]]{4}:[[:xdigit:]]{4}$ ]] || \
        die "EXPECTED_PCI_ID must have vendor:device form, got ${EXPECTED_PCI_ID}"

    if [[ -n "${PCIE_BDF:-}" ]]; then
        normalize_bdf "${PCIE_BDF}"
        return
    fi

    while IFS= read -r line; do
        [[ -n "${line}" ]] && candidates+=("${line}")
    done < <(lspci -Dnn | awk -v expected="${EXPECTED_PCI_ID,,}" \
        'index(tolower($0), "[" expected "]") && $1 ~ /\.1$/ {print $1}')

    if (( ${#candidates[@]} == 0 )); then
        die "no ${EXPECTED_PCI_ID} function .1 was detected; verify the FPGA image or override EXPECTED_PCI_ID and PCIE_BDF intentionally"
    fi
    if (( ${#candidates[@]} > 1 )); then
        warn "multiple possible CHMU/CXL PCI functions were detected: ${candidates[*]}"
        die "rerun detect with an explicit PCIE_BDF value"
    fi

    normalize_bdf "${candidates[0]}"
}

node_has_memory() {
    local node_dir="$1"
    compgen -G "${node_dir}/memory[0-9]*" >/dev/null
}

node_has_cpus() {
    local node_dir="$1"
    local cpus
    [[ -r "${node_dir}/cpulist" ]] || return 1
    cpus="$(tr -d '[:space:]' < "${node_dir}/cpulist")"
    [[ -n "${cpus}" ]]
}

detect_cxl_node() {
    local node_dir
    local node_number
    local cpulist
    local -a candidates=()

    if [[ -n "${CXL_NODE:-}" ]]; then
        [[ "${CXL_NODE}" =~ ^[0-9]+$ ]] || die "CXL_NODE must be numeric"
        node_dir="/sys/devices/system/node/node${CXL_NODE}"
        [[ -d "${node_dir}" ]] || die "CXL node does not exist: ${node_dir}"
        node_has_memory "${node_dir}" || die "CXL node has no memory blocks: ${node_dir}"
        if node_has_cpus "${node_dir}"; then
            die "CXL_NODE must be a memory-only NUMA node for this artifact: ${CXL_NODE}"
        fi
        printf '%s\n' "${CXL_NODE}"
        return
    fi

    for node_dir in /sys/devices/system/node/node[0-9]*; do
        [[ -d "${node_dir}" ]] || continue
        node_has_memory "${node_dir}" || continue
        cpulist="$(tr -d '[:space:]' < "${node_dir}/cpulist")"
        if [[ -z "${cpulist}" ]]; then
            node_number="${node_dir##*node}"
            candidates+=("${node_number}")
        fi
    done

    if (( ${#candidates[@]} == 0 )); then
        die "no memory-only NUMA node was detected; rerun with CXL_NODE=<node>"
    fi
    if (( ${#candidates[@]} > 1 )); then
        warn "multiple memory-only NUMA nodes were detected: ${candidates[*]}"
        die "rerun detect with an explicit CXL_NODE value"
    fi
    printf '%s\n' "${candidates[0]}"
}

detect_buffer_node() {
    local cxl_node="$1"
    local node_dir
    local node_number
    local cpulist

    if [[ -n "${BUFFER_NODE:-}" ]]; then
        [[ "${BUFFER_NODE}" =~ ^[0-9]+$ ]] || die "BUFFER_NODE must be numeric"
        [[ -d "/sys/devices/system/node/node${BUFFER_NODE}" ]] || \
            die "buffer NUMA node does not exist: ${BUFFER_NODE}"
        [[ "${BUFFER_NODE}" != "${cxl_node}" ]] || \
            die "BUFFER_NODE must differ from CXL_NODE"
        node_has_memory "/sys/devices/system/node/node${BUFFER_NODE}" || \
            die "BUFFER_NODE has no memory: ${BUFFER_NODE}"
        node_has_cpus "/sys/devices/system/node/node${BUFFER_NODE}" || \
            die "BUFFER_NODE has no CPUs: ${BUFFER_NODE}"
        printf '%s\n' "${BUFFER_NODE}"
        return
    fi

    if [[ "${cxl_node}" != 0 ]] && \
       node_has_memory /sys/devices/system/node/node0 && \
       node_has_cpus /sys/devices/system/node/node0; then
        printf '0\n'
        return
    fi

    for node_dir in /sys/devices/system/node/node[0-9]*; do
        [[ -d "${node_dir}" ]] || continue
        node_has_memory "${node_dir}" || continue
        node_number="${node_dir##*node}"
        [[ "${node_number}" != "${cxl_node}" ]] || continue
        cpulist="$(tr -d '[:space:]' < "${node_dir}/cpulist")"
        if [[ -n "${cpulist}" ]]; then
            printf '%s\n' "${node_number}"
            return
        fi
    done
    die "no DRAM buffer NUMA node was detected; rerun with BUFFER_NODE=<node>"
}

write_env_value() {
    local name="$1"
    local value="$2"
    printf '%s=%q\n' "${name}" "${value}"
}

detect_platform() {
    local detected_bdf
    local bar2_path
    local detected_cxl_node
    local detected_buffer_node
    local node_dir
    local first_memory_block
    local phys_index
    local block_size_hex
    local phys_index_dec
    local block_size_dec
    local cxl_mem_start_dec
    local cxl_mem_start
    local cxl_mem_pfn
    local mem_total_kb
    local cxl_mem_num_pfn
    local temporary_file
    local device_info
    local bar2_size
    local memory_block
    local memory_block_state
    local block_phys_index
    local block_phys_index_dec
    local expected_phys_index_dec
    local -a memory_blocks=()

    info "detecting SPR1 PCI and NUMA topology"
    detected_bdf="$(detect_pcie_bdf)"
    [[ "${detected_bdf}" == *.1 ]] || die "CHMU PCI function must be function .1: ${detected_bdf}"
    device_info="$(lspci -Dnn -s "${detected_bdf}")"
    [[ -n "${device_info}" ]] || die "PCI function is not present: ${detected_bdf}"
    if [[ "${device_info,,}" != *"[${EXPECTED_PCI_ID,,}]"* ]]; then
        die "PCI function ${detected_bdf} is not expected device ${EXPECTED_PCI_ID}: ${device_info}"
    fi
    bar2_path="/sys/bus/pci/devices/${detected_bdf}/resource2"
    [[ -e "${bar2_path}" ]] || die "BAR2 resource was not found: ${bar2_path}"
    bar2_size="$(stat -c '%s' "${bar2_path}")"
    [[ "${BAR2_MIN_SIZE_BYTES}" =~ ^[1-9][0-9]*$ ]] || \
        die "BAR2_MIN_SIZE_BYTES must be a positive decimal integer"
    (( bar2_size >= BAR2_MIN_SIZE_BYTES )) || \
        die "BAR2 is ${bar2_size} bytes, but migration_manager maps ${BAR2_MIN_SIZE_BYTES} bytes"

    detected_cxl_node="$(detect_cxl_node)"
    detected_buffer_node="$(detect_buffer_node "${detected_cxl_node}")"
    node_dir="/sys/devices/system/node/node${detected_cxl_node}"

    mapfile -t memory_blocks < <(compgen -G "${node_dir}/memory[0-9]*" | sort -V)
    first_memory_block="${memory_blocks[0]:-}"
    [[ -n "${first_memory_block}" ]] || die "no memory block found below ${node_dir}"
    [[ -r "${first_memory_block}/phys_index" ]] || \
        die "cannot read ${first_memory_block}/phys_index"
    [[ -r /sys/devices/system/memory/block_size_bytes ]] || \
        die "cannot read the system memory block size"

    phys_index="$(tr -d '[:space:]' < "${first_memory_block}/phys_index")"
    block_size_hex="$(tr -d '[:space:]' < /sys/devices/system/memory/block_size_bytes)"
    phys_index="${phys_index#0x}"
    block_size_hex="${block_size_hex#0x}"
    [[ "${phys_index}" =~ ^[[:xdigit:]]+$ ]] || die "invalid memory phys_index: ${phys_index}"
    [[ "${block_size_hex}" =~ ^[[:xdigit:]]+$ ]] || die "invalid memory block size: ${block_size_hex}"

    phys_index_dec=$((16#${phys_index}))
    block_size_dec=$((16#${block_size_hex}))
    (( block_size_dec % 4096 == 0 )) || die "memory block size is not 4 KiB aligned"

    expected_phys_index_dec="${phys_index_dec}"
    for memory_block in "${memory_blocks[@]}"; do
        [[ -r "${memory_block}/phys_index" ]] || \
            die "cannot read ${memory_block}/phys_index"
        block_phys_index="$(tr -d '[:space:]' < "${memory_block}/phys_index")"
        block_phys_index="${block_phys_index#0x}"
        [[ "${block_phys_index}" =~ ^[[:xdigit:]]+$ ]] || \
            die "invalid phys_index in ${memory_block}: ${block_phys_index}"
        block_phys_index_dec=$((16#${block_phys_index}))
        (( block_phys_index_dec == expected_phys_index_dec )) || \
            die "CXL memory blocks are not contiguous at ${memory_block}"
        expected_phys_index_dec=$((expected_phys_index_dec + 1))

        if [[ -r "${memory_block}/state" ]]; then
            memory_block_state="$(tr -d '[:space:]' < "${memory_block}/state")"
            [[ "${memory_block_state}" == online* ]] || \
                die "CXL memory block is not online: ${memory_block} (${memory_block_state})"
        fi
    done

    cxl_mem_start_dec=$((phys_index_dec * block_size_dec))
    printf -v cxl_mem_start '0x%x' "${cxl_mem_start_dec}"
    printf -v cxl_mem_pfn '0x%x' "$((cxl_mem_start_dec >> 12))"

    mem_total_kb="$(awk '/MemTotal:/ {print $4; exit}' "${node_dir}/meminfo")"
    [[ "${mem_total_kb}" =~ ^[0-9]+$ ]] || die "could not determine CXL node memory size"
    cxl_mem_num_pfn=$(( ${#memory_blocks[@]} * block_size_dec / 4096 ))
    (( cxl_mem_num_pfn > 0 )) || die "detected CXL memory size is zero"

    mkdir -p "$(dirname -- "${PLATFORM_CONFIG_FILE}")"
    temporary_file="${PLATFORM_CONFIG_FILE}.tmp"
    {
        printf '#!/usr/bin/env bash\n\n'
        printf '# Generated by set_default/setup_default.sh detect on %s.\n' \
            "$(date --iso-8601=seconds)"
        printf '# Do not commit this host-specific file.\n'
        write_env_value PCIE_BDF "${detected_bdf}"
        write_env_value PCIE_ADDR "${detected_bdf#????:}"
        write_env_value BAR2_PATH "${bar2_path}"
        write_env_value CXL_NODE "${detected_cxl_node}"
        write_env_value BUFFER_NODE "${detected_buffer_node}"
        write_env_value CXL_MEM_START "${cxl_mem_start}"
        write_env_value CXL_MEM_PFN "${cxl_mem_pfn}"
        write_env_value CXL_MEM_NUM_PFN "${cxl_mem_num_pfn}"
        write_env_value MEMORY_BLOCK_SIZE "0x${block_size_hex}"
    } > "${temporary_file}"
    mv -- "${temporary_file}" "${PLATFORM_CONFIG_FILE}"

    info "platform configuration written to ${PLATFORM_CONFIG_FILE}"
    printf '  PCI BDF:       %s\n' "${detected_bdf}"
    printf '  BAR2:          %s\n' "${bar2_path}"
    printf '  CXL node:      %s\n' "${detected_cxl_node}"
    printf '  Buffer node:   %s\n' "${detected_buffer_node}"
    printf '  CXL start:     %s\n' "${cxl_mem_start}"
    printf '  CXL first PFN: %s\n' "${cxl_mem_pfn}"
    printf '  CXL PFN count: %s\n' "${cxl_mem_num_pfn}"
}

build_software() {
    local threshold
    local build_dir
    local build_jobs="${BUILD_JOBS:-}"
    local temporary_file
    local page_vermagic
    local overflow_vermagic
    local module_source

    if [[ ! -r "${PLATFORM_CONFIG_FILE}" ]]; then
        detect_platform
    fi
    require_platform_config
    [[ -n "${build_jobs}" ]] || build_jobs="$(nproc 2>/dev/null || printf '1')"
    [[ "${build_jobs}" =~ ^[1-9][0-9]*$ ]] || die "BUILD_JOBS must be a positive integer"

    info "building pcimem"
    make -C "${SW_DIR}/pcimem"

    if kernel_modules_are_reusable 1; then
        module_source="${REUSABLE_MODULE_SOURCE}"
        info "using ${module_source} kernel modules; skipping both module builds"
    else
        [[ -d "${KERNEL_BUILD}" ]] || \
            die "kernel modules are not reusable and the fallback build tree is missing: ${KERNEL_BUILD}"
        info "building page_migrate for kernel $(uname -r)"
        make -C "${SW_DIR}/kmod_pgmigrate" \
            KDIR="${KERNEL_BUILD}" \
            CXL_MEM_PFN_BEGIN="${CXL_MEM_PFN}" \
            CXL_MEM_NUM_PFN="${CXL_MEM_NUM_PFN}"

        info "building pac_ofw_buf for CXL node ${CXL_NODE}, buffer node ${BUFFER_NODE}"
        make -C "${SW_DIR}/kmod_pac_ofw_buf" \
            KDIR="${KERNEL_BUILD}" \
            CXL_NODE="${CXL_NODE}" \
            MEMORY_ALLOC_NODE="${BUFFER_NODE}"
        module_source="source-build"
    fi

    for threshold in "${BUILD_THRESHOLDS[@]}"; do
        build_dir="${SW_DIR}/build_option_th${threshold}"
        info "configuring migration manager in ${build_dir}"
        cmake \
            -S "${SW_DIR}/migration_manager" \
            -B "${build_dir}" \
            -DCMAKE_BUILD_TYPE=Release \
            -DAE_BAR_PATH="${BAR2_PATH}" \
            -DAE_CXL_MEM_START="${CXL_MEM_START}" \
            -DAE_CXL_MEM_PFN="${CXL_MEM_PFN}" \
            -DAE_CXL_MEM_NUM_PFN="${CXL_MEM_NUM_PFN}" \
            -DAE_CXL_NODE="${CXL_NODE}" \
            -DAE_MIGRATION_TARGET_NODE="${BUFFER_NODE}"
        cmake --build "${build_dir}" --parallel "${build_jobs}"
    done

    page_vermagic="$(modinfo -F vermagic "${SW_DIR}/kmod_pgmigrate/page_migrate.ko" | awk '{print $1}')"
    overflow_vermagic="$(modinfo -F vermagic "${SW_DIR}/kmod_pac_ofw_buf/pac_ofw_buf.ko" | awk '{print $1}')"
    [[ "${page_vermagic}" == "$(uname -r)" ]] || \
        die "page_migrate vermagic ${page_vermagic} does not match $(uname -r)"
    [[ "${overflow_vermagic}" == "$(uname -r)" ]] || \
        die "pac_ofw_buf vermagic ${overflow_vermagic} does not match $(uname -r)"

    mkdir -p "$(dirname -- "${BUILD_CONFIG_FILE}")"
    temporary_file="${BUILD_CONFIG_FILE}.tmp"
    {
        printf '#!/usr/bin/env bash\n\n'
        printf '# Generated only after every artifact build succeeds.\n'
        write_env_value BUILT_MODULE_SOURCE "${module_source}"
        write_env_value BUILT_KERNEL_RELEASE "$(uname -r)"
        write_env_value BUILT_PCIE_BDF "${PCIE_BDF}"
        write_env_value BUILT_BAR2_PATH "${BAR2_PATH}"
        write_env_value BUILT_CXL_MEM_START "${CXL_MEM_START}"
        write_env_value BUILT_CXL_MEM_PFN "${CXL_MEM_PFN}"
        write_env_value BUILT_CXL_MEM_NUM_PFN "${CXL_MEM_NUM_PFN}"
        write_env_value BUILT_CXL_NODE "${CXL_NODE}"
        write_env_value BUILT_BUFFER_NODE "${BUFFER_NODE}"
        write_env_value BUILT_PAGE_MODULE_SHA256 \
            "$(sha256sum "${SW_DIR}/kmod_pgmigrate/page_migrate.ko" | awk '{print $1}')"
        write_env_value BUILT_OVERFLOW_MODULE_SHA256 \
            "$(sha256sum "${SW_DIR}/kmod_pac_ofw_buf/pac_ofw_buf.ko" | awk '{print $1}')"
    } > "${temporary_file}"
    mv -- "${temporary_file}" "${BUILD_CONFIG_FILE}"

    info "all four manager directories were built"
}

set_cpu_frequency() {
    local governor_file
    local setspeed_file
    local found=0

    for governor_file in /sys/devices/system/cpu/cpu[0-9]*/cpufreq/scaling_governor; do
        [[ -e "${governor_file}" ]] || continue
        cpu_frequency_control_is_active "${governor_file}" || continue
        found=1
        write_root_value "${governor_file}" userspace
        setspeed_file="${governor_file%/*}/scaling_setspeed"
        write_root_value "${setspeed_file}" "${CPU_FREQUENCY_KHZ}"
        [[ "$(< "${governor_file}")" == userspace ]] || \
            die "userspace governor did not latch at ${governor_file}"
        [[ "$(< "${setspeed_file}")" == "${CPU_FREQUENCY_KHZ}" ]] || \
            die "CPU frequency did not latch at ${setspeed_file}"
    done
    (( found == 1 )) || die "no CPU frequency control files were found"
}

validate_apply_controls() {
    local setting_file
    local governor_file
    local available_governors
    local cpu
    local msr_value

    [[ "${CPU_FREQUENCY_KHZ}" =~ ^[1-9][0-9]*$ ]] || \
        die "CPU_FREQUENCY_KHZ must be a positive decimal integer"
    [[ "${UNCORE_RATIO_VALUE}" =~ ^(0x[[:xdigit:]]+|[0-9]+)$ ]] || \
        die "UNCORE_RATIO_VALUE must be an unsigned integer"
    [[ "${NUMA_BALANCING_MODE}" =~ ^[0-9]+$ ]] || \
        die "NUMA_BALANCING_MODE must be numeric"
    [[ "${NUMA_DEMOTION_ENABLED}" =~ ^[01]$ ]] || \
        die "NUMA_DEMOTION_ENABLED must be 0 or 1"
    [[ "${RESET_SWAP}" =~ ^[01]$ ]] || die "RESET_SWAP must be 0 or 1"

    for setting_file in \
        /sys/kernel/mm/numa/demotion_enabled \
        /proc/sys/kernel/numa_balancing \
        /proc/sys/vm/drop_caches; do
        [[ -e "${setting_file}" ]] || die "required control file is missing: ${setting_file}"
    done

    for governor_file in /sys/devices/system/cpu/cpu[0-9]*/cpufreq/scaling_governor; do
        [[ -e "${governor_file}" ]] || continue
        cpu_frequency_control_is_active "${governor_file}" || continue
        [[ -r "${governor_file%/*}/scaling_available_governors" ]] || \
            die "available governors file is missing below ${governor_file%/*}"
        [[ -e "${governor_file%/*}/scaling_setspeed" ]] || \
            die "scaling_setspeed is missing below ${governor_file%/*}"
        available_governors="$(< "${governor_file%/*}/scaling_available_governors")"
        [[ " ${available_governors} " == *' userspace '* ]] || \
            die "userspace governor is unavailable below ${governor_file%/*}"
    done

    while IFS= read -r cpu; do
        msr_value="$(run_root rdmsr -p "${cpu}" 0x1a0)"
        [[ "${msr_value}" =~ ^[[:xdigit:]]+$ ]] || \
            die "cannot read IA32_MISC_ENABLE on CPU ${cpu}"
        msr_value="$(run_root rdmsr -p "${cpu}" 0x620)"
        [[ "${msr_value}" =~ ^[[:xdigit:]]+$ ]] || \
            die "cannot read uncore ratio MSR on CPU ${cpu}"
    done < <(awk '/^processor[[:space:]]*:/ {print $3}' /proc/cpuinfo)
}

check_swap_reset_capacity() {
    local swap_total_kb
    local swap_free_kb
    local swap_used_kb
    local mem_available_kb

    [[ "${SWAP_RESET_HEADROOM_KB}" =~ ^[0-9]+$ ]] || \
        die "SWAP_RESET_HEADROOM_KB must be numeric"
    swap_total_kb="$(awk '/^SwapTotal:/ {print $2}' /proc/meminfo)"
    swap_free_kb="$(awk '/^SwapFree:/ {print $2}' /proc/meminfo)"
    mem_available_kb="$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo)"
    [[ "${swap_total_kb}" =~ ^[0-9]+$ &&
       "${swap_free_kb}" =~ ^[0-9]+$ &&
       "${mem_available_kb}" =~ ^[0-9]+$ ]] || \
        die "could not read swap/memory capacity from /proc/meminfo"
    swap_used_kb=$((swap_total_kb - swap_free_kb))
    if (( swap_used_kb > 0 &&
          mem_available_kb < swap_used_kb + SWAP_RESET_HEADROOM_KB )); then
        die "swap reset needs ${swap_used_kb} KiB plus ${SWAP_RESET_HEADROOM_KB} KiB headroom, but only ${mem_available_kb} KiB is available; use RESET_SWAP=0 only after reviewing the experiment state"
    fi
}

disable_turbo_boost() {
    local cpu
    local current_hex
    local current_dec
    local updated_dec
    local updated_hex
    local disabled_bit

    while IFS= read -r cpu; do
        current_hex="$(run_root rdmsr -p "${cpu}" 0x1a0)"
        [[ "${current_hex}" =~ ^[[:xdigit:]]+$ ]] || \
            die "cannot read IA32_MISC_ENABLE on CPU ${cpu}"
        current_dec=$((16#${current_hex}))
        updated_dec=$((current_dec | (1 << 38)))
        printf -v updated_hex '0x%x' "${updated_dec}"
        run_root wrmsr -p "${cpu}" 0x1a0 "${updated_hex}"
        disabled_bit="$(run_root rdmsr -p "${cpu}" 0x1a0 -f 38:38)"
        [[ "${disabled_bit}" == 1 ]] || die "turbo disable bit did not latch on CPU ${cpu}"
    done < <(awk '/^processor[[:space:]]*:/ {print $3}' /proc/cpuinfo)
}

set_uncore_ratio() {
    local cpu
    local readback_hex
    local expected_dec

    if [[ "${UNCORE_RATIO_VALUE}" == 0x* ]]; then
        expected_dec=$((16#${UNCORE_RATIO_VALUE#0x}))
    else
        expected_dec=$((10#${UNCORE_RATIO_VALUE}))
    fi
    run_root wrmsr -a 0x620 "${UNCORE_RATIO_VALUE}"
    while IFS= read -r cpu; do
        readback_hex="$(run_root rdmsr -p "${cpu}" 0x620)"
        [[ "${readback_hex}" =~ ^[[:xdigit:]]+$ ]] || \
            die "cannot verify uncore ratio on CPU ${cpu}"
        (( 16#${readback_hex} == expected_dec )) || \
            die "uncore ratio did not latch on CPU ${cpu}"
    done < <(awk '/^processor[[:space:]]*:/ {print $3}' /proc/cpuinfo)
}

module_is_loaded() {
    grep -q "^$1 " /proc/modules
}

reload_modules() {
    local page_module="${SW_DIR}/kmod_pgmigrate/page_migrate.ko"
    local overflow_module="${SW_DIR}/kmod_pac_ofw_buf/pac_ofw_buf.ko"

    [[ -r "${page_module}" ]] || die "module was not built: ${page_module}"
    [[ -r "${overflow_module}" ]] || die "module was not built: ${overflow_module}"

    if module_is_loaded pac_ofw_buf; then
        run_root rmmod pac_ofw_buf
    fi
    if module_is_loaded page_migrate; then
        run_root rmmod page_migrate
    fi

    run_root insmod "${page_module}"
    if ! run_root insmod "${overflow_module}"; then
        run_root rmmod page_migrate || true
        return 1
    fi
}

verify_module_builds() {
    local page_module="${SW_DIR}/kmod_pgmigrate/page_migrate.ko"
    local overflow_module="${SW_DIR}/kmod_pac_ofw_buf/pac_ofw_buf.ko"
    local page_hash
    local overflow_hash
    local page_vermagic
    local overflow_vermagic

    [[ -r "${BUILD_CONFIG_FILE}" ]] || \
        die "successful build stamp is missing; rerun '$0 build'"
    # shellcheck source=/dev/null
    source "${BUILD_CONFIG_FILE}"

    case "${BUILT_MODULE_SOURCE:-}" in
        bundled-prebuilt|existing-build|source-build) ;;
        *) die "kernel-module build stamp has an unknown source; rerun '$0 build'" ;;
    esac

    [[ "${BUILT_KERNEL_RELEASE:-}" == "$(uname -r)" &&
       "${BUILT_PCIE_BDF:-}" == "${PCIE_BDF}" &&
       "${BUILT_BAR2_PATH:-}" == "${BAR2_PATH}" &&
       "${BUILT_CXL_MEM_START:-}" == "${CXL_MEM_START}" &&
       "${BUILT_CXL_MEM_PFN:-}" == "${CXL_MEM_PFN}" &&
       "${BUILT_CXL_MEM_NUM_PFN:-}" == "${CXL_MEM_NUM_PFN}" &&
       "${BUILT_CXL_NODE:-}" == "${CXL_NODE}" &&
       "${BUILT_BUFFER_NODE:-}" == "${BUFFER_NODE}" ]] || \
        die "kernel-module build stamp does not match platform.env; rerun '$0 build'"

    page_hash="$(sha256sum "${page_module}" | awk '{print $1}')"
    overflow_hash="$(sha256sum "${overflow_module}" | awk '{print $1}')"
    [[ "${page_hash}" == "${BUILT_PAGE_MODULE_SHA256:-}" ]] || \
        die "page_migrate.ko changed after the successful build"
    [[ "${overflow_hash}" == "${BUILT_OVERFLOW_MODULE_SHA256:-}" ]] || \
        die "pac_ofw_buf.ko changed after the successful build"
    if [[ "${BUILT_MODULE_SOURCE}" == bundled-prebuilt ]]; then
        [[ "${page_hash}" == "${BUNDLED_PAGE_MODULE_SHA256}" &&
           "${overflow_hash}" == "${BUNDLED_OVERFLOW_MODULE_SHA256}" &&
           "${CXL_NODE}" == "${BUNDLED_CXL_NODE}" &&
           "${BUFFER_NODE}" == "${BUNDLED_BUFFER_NODE}" ]] || \
            die "bundled kernel modules do not match their fixed SPR1 configuration"
    fi

    page_vermagic="$(modinfo -F vermagic "${page_module}" | awk '{print $1}')"
    overflow_vermagic="$(modinfo -F vermagic "${overflow_module}" | awk '{print $1}')"
    [[ "${page_vermagic}" == "$(uname -r)" ]] || \
        die "page_migrate vermagic does not match the running kernel"
    [[ "${overflow_vermagic}" == "$(uname -r)" ]] || \
        die "pac_ofw_buf vermagic does not match the running kernel"
}

verify_manager_build() {
    local threshold="$1"
    local build_dir="${SW_DIR}/build_option_th${threshold}"
    local cache_file="${build_dir}/CMakeCache.txt"
    local expected_entry
    local -a expected_entries=(
        "AE_BAR_PATH:STRING=${BAR2_PATH}"
        "AE_CXL_MEM_START:STRING=${CXL_MEM_START}"
        "AE_CXL_MEM_PFN:STRING=${CXL_MEM_PFN}"
        "AE_CXL_MEM_NUM_PFN:STRING=${CXL_MEM_NUM_PFN}"
        "AE_CXL_NODE:STRING=${CXL_NODE}"
        "AE_MIGRATION_TARGET_NODE:STRING=${BUFFER_NODE}"
    )

    [[ -x "${build_dir}/migration_manager" ]] || \
        die "build_option_th${threshold} is not built; run '$0 build' first"
    [[ -r "${cache_file}" ]] || \
        die "build configuration is missing: ${cache_file}; rerun '$0 build'"

    for expected_entry in "${expected_entries[@]}"; do
        grep -Fqx "${expected_entry}" "${cache_file}" || \
            die "build_option_th${threshold} does not match platform.env; rerun '$0 build'"
    done
}

rollback_apply_failure() {
    local failure_status=$?
    trap - EXIT
    set +e
    warn "apply failed; unloading artifact modules and restoring NUMA controls"
    if [[ -x "${SW_DIR}/pcimem/pcimem" && -e "${BAR2_PATH:-}" ]]; then
        bash "${SW_DIR}/set_para/tracker.sh" disable >/dev/null 2>&1
    fi
    if [[ "${APPLY_MODULES_LOADED:-0}" == 1 ]]; then
        module_is_loaded pac_ofw_buf && run_root rmmod pac_ofw_buf
        module_is_loaded page_migrate && run_root rmmod page_migrate
    fi
    if [[ -n "${ORIGINAL_NUMA_BALANCING:-}" ]]; then
        write_root_value /proc/sys/kernel/numa_balancing "${ORIGINAL_NUMA_BALANCING}"
    fi
    if [[ -n "${ORIGINAL_NUMA_DEMOTION:-}" ]]; then
        write_root_value /sys/kernel/mm/numa/demotion_enabled "${ORIGINAL_NUMA_DEMOTION}"
    fi
    exit "${failure_status}"
}

apply_defaults() {
    local threshold
    local page_module="${SW_DIR}/kmod_pgmigrate/page_migrate.ko"
    local overflow_module="${SW_DIR}/kmod_pac_ofw_buf/pac_ofw_buf.ko"
    local ORIGINAL_NUMA_BALANCING
    local ORIGINAL_NUMA_DEMOTION
    local APPLY_MODULES_LOADED=0
    local demotion_readback
    local demotion_normalized

    if [[ "${PREFLIGHT_COMPLETE}" != 1 ]]; then
        check_requirements
    fi
    require_platform_config
    [[ -e "${BAR2_PATH}" ]] || die "detected BAR2 path is unavailable: ${BAR2_PATH}"
    lspci -s "${PCIE_BDF}" >/dev/null 2>&1 || \
        die "detected PCI function is unavailable: ${PCIE_BDF}"
    for threshold in "${BUILD_THRESHOLDS[@]}"; do
        verify_manager_build "${threshold}"
    done
    [[ -x "${SW_DIR}/pcimem/pcimem" ]] || die "pcimem is not built; run '$0 build' first"
    [[ -r "${page_module}" ]] || die "module is not built: ${page_module}"
    [[ -r "${overflow_module}" ]] || die "module is not built: ${overflow_module}"
    verify_module_builds

    info "acquiring administrative privileges"
    if (( EUID != 0 )); then
        sudo -v
    fi

    run_root modprobe msr
    validate_apply_controls
    ORIGINAL_NUMA_BALANCING="$(< /proc/sys/kernel/numa_balancing)"
    ORIGINAL_NUMA_DEMOTION="$(< /sys/kernel/mm/numa/demotion_enabled)"

    if [[ "${RESET_SWAP}" == 1 ]]; then
        check_swap_reset_capacity
        info "resetting swap, matching the original SPR1 setup"
        run_root swapoff -a
        run_root swapon -a
    fi

    trap rollback_apply_failure EXIT

    info "loading migration and overflow-buffer modules"
    reload_modules
    APPLY_MODULES_LOADED=1

    info "disabling turbo and fixing CPU/uncore frequency"
    disable_turbo_boost
    set_cpu_frequency
    set_uncore_ratio

    if command -v systemctl >/dev/null 2>&1 && \
       systemctl list-unit-files numad.service --no-legend 2>/dev/null | \
           grep -q '^numad\.service'; then
        run_root systemctl stop numad.service
        run_root systemctl disable numad.service
    fi

    info "applying NUMA migration defaults"
    write_root_value /sys/kernel/mm/numa/demotion_enabled "${NUMA_DEMOTION_ENABLED}"
    write_root_value /proc/sys/kernel/numa_balancing "${NUMA_BALANCING_MODE}"
    write_root_value /proc/sys/vm/drop_caches 3

    info "initializing BAR2 CHMU registers"
    bash "${SW_DIR}/set_para/initialize_hardware.sh"
    [[ "$(< /proc/sys/kernel/numa_balancing)" == "${NUMA_BALANCING_MODE}" ]] || \
        die "NUMA balancing mode did not latch"
    demotion_readback="$(< /sys/kernel/mm/numa/demotion_enabled)"
    if ! demotion_normalized="$(normalize_kernel_bool "${demotion_readback}")"; then
        die "invalid NUMA demotion readback: ${demotion_readback}"
    fi
    [[ "${demotion_normalized}" == "${NUMA_DEMOTION_ENABLED}" ]] || \
        die "NUMA demotion setting did not latch (requested ${NUMA_DEMOTION_ENABLED}, read back ${demotion_readback})"
    module_is_loaded page_migrate || die "page_migrate is not loaded after apply"
    module_is_loaded pac_ofw_buf || die "pac_ofw_buf is not loaded after apply"
    trap - EXIT
    info "SPR1 defaults are applied"
}

show_status() {
    local threshold

    require_platform_config
    printf 'Kernel: %s\n' "$(uname -r)"
    printf 'Platform configuration: %s\n' "${PLATFORM_CONFIG_FILE}"
    printf '  PCIE_BDF=%s\n' "${PCIE_BDF}"
    printf '  BAR2_PATH=%s\n' "${BAR2_PATH}"
    printf '  CXL_NODE=%s\n' "${CXL_NODE}"
    printf '  BUFFER_NODE=%s\n' "${BUFFER_NODE}"
    printf '  CXL_MEM_START=%s\n' "${CXL_MEM_START}"
    printf '  CXL_MEM_PFN=%s\n' "${CXL_MEM_PFN}"
    printf '  CXL_MEM_NUM_PFN=%s\n' "${CXL_MEM_NUM_PFN}"

    for threshold in "${BUILD_THRESHOLDS[@]}"; do
        if [[ -x "${SW_DIR}/build_option_th${threshold}/migration_manager" ]]; then
            printf '  build_option_th%s: built\n' "${threshold}"
        else
            printf '  build_option_th%s: not built\n' "${threshold}"
        fi
    done

    if module_is_loaded page_migrate; then
        printf '  page_migrate: loaded\n'
    else
        printf '  page_migrate: not loaded\n'
    fi
    if module_is_loaded pac_ofw_buf; then
        printf '  pac_ofw_buf: loaded\n'
    else
        printf '  pac_ofw_buf: not loaded\n'
    fi

    if [[ -r /proc/sys/kernel/numa_balancing ]]; then
        printf '  numa_balancing=%s\n' "$(< /proc/sys/kernel/numa_balancing)"
    fi
    if [[ -r /sys/kernel/mm/numa/demotion_enabled ]]; then
        printf '  demotion_enabled=%s\n' "$(< /sys/kernel/mm/numa/demotion_enabled)"
    fi
}

disable_artifact() {
    require_platform_config
    if (( EUID != 0 )); then
        sudo -v
    fi

    if [[ -x "${SW_DIR}/pcimem/pcimem" && -e "${BAR2_PATH}" ]]; then
        bash "${SW_DIR}/set_para/tracker.sh" disable
    else
        warn "pcimem or BAR2 is unavailable; skipping the tracker register write"
    fi

    if module_is_loaded pac_ofw_buf; then
        run_root rmmod pac_ofw_buf
    fi
    if module_is_loaded page_migrate; then
        run_root rmmod page_migrate
    fi
    write_root_value /sys/kernel/mm/numa/demotion_enabled 0
    info "CHMU tracking is disabled and artifact modules are unloaded"
}

main() {
    local command="${1:-}"

    case "${command}" in
        check)
            require_target_host
            ;;
        detect|build|apply|all|disable)
            require_target_host
            acquire_exclusive_lock
            ;;
    esac

    case "${command}" in
        check)
            check_requirements
            ;;
        detect)
            detect_platform
            ;;
        build)
            build_software
            ;;
        apply)
            apply_defaults
            ;;
        all)
            check_requirements
            detect_platform
            build_software
            apply_defaults
            show_status
            ;;
        status)
            show_status
            ;;
        disable)
            disable_artifact
            ;;
        -h|--help|help)
            usage
            ;;
        *)
            usage >&2
            exit 2
            ;;
    esac
}

main "$@"
