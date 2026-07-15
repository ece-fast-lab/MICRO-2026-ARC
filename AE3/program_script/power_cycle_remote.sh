#!/usr/bin/env bash

set -euo pipefail

: "${BMC_HOST:?Set BMC_HOST to the SPR1 BMC address}"
: "${BMC_USER:?Set BMC_USER to the SPR1 BMC account}"
: "${IPMI_PASSWORD:?Export IPMI_PASSWORD without placing it on the command line}"

if [[ "${CONFIRM_POWER_CYCLE:-}" != "SPR1" ]]; then
    echo "ERROR: set CONFIRM_POWER_CYCLE=SPR1 to confirm the destructive power cycle" >&2
    exit 2
fi

ipmitool \
    -H "${BMC_HOST}" \
    -U "${BMC_USER}" \
    -E \
    -I "${BMC_INTERFACE:-lanplus}" \
    power cycle
