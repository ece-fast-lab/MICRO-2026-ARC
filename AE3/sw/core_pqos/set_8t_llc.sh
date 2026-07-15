#!/usr/bin/env bash

set -euo pipefail

# SPR1 experiment topology: workload CPUs 0-7, manager CPU 20, 15 LLC ways.
WORKLOAD_CPU_FIRST="${WORKLOAD_CPU_FIRST:-0}"
WORKLOAD_CPU_LAST="${WORKLOAD_CPU_LAST:-7}"
MIGRATION_CPU="${MIGRATION_CPU:-20}"
SPR1_CPU_LAST="${SPR1_CPU_LAST:-31}"

for numeric_value in \
    "${WORKLOAD_CPU_FIRST}" "${WORKLOAD_CPU_LAST}" \
    "${MIGRATION_CPU}" "${SPR1_CPU_LAST}"; do
    [[ "${numeric_value}" =~ ^[0-9]+$ ]] || {
        echo "ERROR: CPU identifiers must be non-negative integers" >&2
        exit 2
    }
done
(( WORKLOAD_CPU_FIRST <= WORKLOAD_CPU_LAST )) || {
    echo "ERROR: WORKLOAD_CPU_FIRST must not exceed WORKLOAD_CPU_LAST" >&2
    exit 2
}
(( MIGRATION_CPU > WORKLOAD_CPU_LAST && MIGRATION_CPU <= SPR1_CPU_LAST )) || {
    echo "ERROR: MIGRATION_CPU must be outside the workload range and present on SPR1" >&2
    exit 2
}

run_root() {
    if (( EUID == 0 )); then
        "$@"
    else
        sudo "$@"
    fi
}

set_cpu_online() {
    local cpu="$1"
    local value="$2"
    local online_file="/sys/devices/system/cpu/cpu${cpu}/online"

    # CPU0 normally has no online control file and is always online.
    if [[ ! -e "${online_file}" ]]; then
        [[ "${cpu}" == 0 ]] && return 0
        echo "ERROR: SPR1 CPU ${cpu} does not exist: ${online_file}" >&2
        return 1
    fi

    if (( EUID == 0 )); then
        printf '%s\n' "${value}" > "${online_file}"
    else
        printf '%s\n' "${value}" | sudo tee "${online_file}" >/dev/null
    fi
}

for ((cpu = WORKLOAD_CPU_LAST + 1; cpu <= SPR1_CPU_LAST; cpu++)); do
    [[ "${cpu}" == "${MIGRATION_CPU}" ]] && continue
    set_cpu_online "${cpu}" 0
done

for ((cpu = WORKLOAD_CPU_FIRST; cpu <= WORKLOAD_CPU_LAST; cpu++)); do
    set_cpu_online "${cpu}" 1
done
set_cpu_online "${MIGRATION_CPU}" 1

run_root pqos -R
run_root pqos -e 'llc@0:1=0x7800'
run_root pqos -a "llc:1=${WORKLOAD_CPU_FIRST}-${WORKLOAD_CPU_LAST}"
run_root pqos -e 'llc@0:2=0x07FF'
run_root pqos -a "llc:2=${MIGRATION_CPU}"

printf 'Online CPUs:  %s\n' "$(< /sys/devices/system/cpu/online)"
printf 'Offline CPUs: %s\n' "$(< /sys/devices/system/cpu/offline)"
