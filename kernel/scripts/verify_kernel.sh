#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
KERNEL_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd -P)"
CONFIG_SNAPSHOT="${KERNEL_DIR}/configs/config-6.11.0-mig-offload+"
EXPECTED_RELEASE="6.11.0-mig-offload+"
EXPECTED_CONFIG_SHA256="20745c0843e064bd76e53bbae0a35e10fe7cb23ba050e255099448a0907e2919"
REQUIRED_CMDLINE=(
    'intel_iommu=on,sm_on'
    'iommu=pt'
    'no5lvl'
    'efi=nosoftreserve'
    'memmap=124G$0x180000000'
)
REQUIRED_SYMBOLS=(cxl_pa_migrate cxl_stats migrate_folio_sync_offload)
REQUIRED_CONFIG=(
    CONFIG_M5=y
    CONFIG_DAMON_PADDR=y
    CONFIG_MIGRATION=y
    CONFIG_CXL_BUS=y
    CONFIG_CXL_PORT=y
    CONFIG_MODVERSIONS=y
)
failures=0

pass() {
    printf 'PASS: %s\n' "$*"
}

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    failures=$((failures + 1))
}

actual_release="$(uname -r)"
if [[ "${actual_release}" == "${EXPECTED_RELEASE}" ]]; then
    pass "running kernel is ${EXPECTED_RELEASE}"
else
    fail "running kernel is ${actual_release}; expected ${EXPECTED_RELEASE}"
fi

cmdline_tokens="$(tr ' ' '\n' < /proc/cmdline)"
for token in "${REQUIRED_CMDLINE[@]}"; do
    if grep -qxF "${token}" <<< "${cmdline_tokens}"; then
        pass "kernel command line contains ${token}"
    else
        fail "kernel command line is missing ${token}"
    fi
done

config_file="/boot/config-${EXPECTED_RELEASE}"
if [[ -r "${config_file}" ]]; then
    actual_config_sha256="$(sha256sum "${config_file}" | awk '{ print $1 }')"
    if [[ "${actual_config_sha256}" == "${EXPECTED_CONFIG_SHA256}" ]]; then
        pass "installed config matches the known-good snapshot"
    elif diff -q \
        <(grep -v '^CONFIG_CC_VERSION_TEXT=' "${CONFIG_SNAPSHOT}") \
        <(grep -v '^CONFIG_CC_VERSION_TEXT=' "${config_file}") >/dev/null; then
        pass 'installed config matches except for CONFIG_CC_VERSION_TEXT metadata'
    else
        fail "installed config hash is ${actual_config_sha256}; expected ${EXPECTED_CONFIG_SHA256}"
    fi
    for config_symbol in "${REQUIRED_CONFIG[@]}"; do
        grep -qxF "${config_symbol}" "${config_file}" &&
            pass "${config_symbol}" || fail "${config_symbol} is absent"
    done
else
    fail "cannot read ${config_file}"
fi

if [[ -r /proc/kallsyms ]]; then
    for symbol in "${REQUIRED_SYMBOLS[@]}"; do
        if awk -v symbol="${symbol}" '$3 == symbol { found = 1 } END { exit !found }' /proc/kallsyms; then
            pass "kernel symbol is present: ${symbol}"
        else
            fail "kernel symbol is absent: ${symbol}"
        fi
    done
else
    fail 'cannot read /proc/kallsyms'
fi

[[ -e /sys/kernel/mm/numa/demotion_enabled ]] &&
    pass 'NUMA demotion control is present' || fail 'NUMA demotion control is absent'

if [[ -d /sys/devices/system/node/node0 && -d /sys/devices/system/node/node1 ]]; then
    pass 'NUMA nodes 0 and 1 are present'
else
    fail 'expected NUMA nodes 0 and 1 are not both present'
fi

if [[ -r /sys/devices/system/node/node0/cpulist ]]; then
    node0_cpus="$(< /sys/devices/system/node/node0/cpulist)"
    [[ "${node0_cpus}" == '0-31' ]] &&
        pass 'NUMA node 0 owns CPUs 0-31' || fail "NUMA node 0 CPU list is ${node0_cpus:-empty}; expected 0-31"
else
    fail 'cannot read NUMA node 0 CPU list'
fi
if [[ -r /sys/devices/system/node/node1/cpulist ]]; then
    node1_cpus="$(< /sys/devices/system/node/node1/cpulist)"
    [[ -z "${node1_cpus}" ]] &&
        pass 'NUMA node 1 is memory-only' || fail "NUMA node 1 unexpectedly owns CPUs: ${node1_cpus}"
else
    fail 'cannot read NUMA node 1 CPU list'
fi
if [[ -r /sys/devices/system/node/node1/meminfo ]] &&
   awk '$1 == "Node" && $3 == "MemTotal:" && $4 > 0 { found = 1 } END { exit !found }' \
       /sys/devices/system/node/node1/meminfo; then
    pass 'NUMA node 1 has memory'
else
    fail 'NUMA node 1 has no visible memory'
fi

if (( failures > 0 )); then
    printf '\nVerification failed with %d issue(s).\n' "${failures}" >&2
    exit 1
fi

printf '\nKernel verification passed.\n'
