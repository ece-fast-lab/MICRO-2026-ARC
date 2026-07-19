#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
KERNEL_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd -P)"
CONFIG_SNAPSHOT="${KERNEL_DIR}/configs/config-6.11.0-mig-offload+"
SOURCE_MANIFEST="${KERNEL_DIR}/SOURCE_SHA256SUMS"
EXPECTED_RELEASE="6.11.0-mig-offload+"
EXPECTED_CONFIG_SHA256="20745c0843e064bd76e53bbae0a35e10fe7cb23ba050e255099448a0907e2919"

usage() {
    printf 'Usage: bash %s SOURCE_DIR BUILD_DIR\n' "${BASH_SOURCE[0]}" >&2
}

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

warn() {
    printf 'WARNING: %s\n' "$*" >&2
}

if [[ $# -ne 2 ]]; then
    usage
    exit 2
fi

for command_name in depmod df make sha256sum sudo update-grub update-initramfs; do
    command -v "${command_name}" >/dev/null 2>&1 ||
        die "required command is not installed: ${command_name}"
done

SOURCE_DIR="$(cd -- "$1" 2>/dev/null && pwd -P)" ||
    die "source directory does not exist: $1"
BUILD_DIR="$(cd -- "$2" 2>/dev/null && pwd -P)" ||
    die "build directory does not exist: $2"

[[ -f "${BUILD_DIR}/.micro-arc-kernel-build" ]] ||
    die "build directory was not created by build_kernel.sh"
(
    cd -- "${SOURCE_DIR}"
    sha256sum --check --status "${SOURCE_MANIFEST}"
) || die "patched source files do not match the captured ARC source"

actual_config_sha256="$(sha256sum "${BUILD_DIR}/.config" | awk '{ print $1 }')"
if [[ "${actual_config_sha256}" != "${EXPECTED_CONFIG_SHA256}" ]] &&
   ! diff -q \
       <(grep -v '^CONFIG_CC_VERSION_TEXT=' "${CONFIG_SNAPSHOT}") \
       <(grep -v '^CONFIG_CC_VERSION_TEXT=' "${BUILD_DIR}/.config") >/dev/null; then
    die "build config differs functionally from the supplied snapshot"
fi

actual_release="$(make -s -C "${SOURCE_DIR}" O="${BUILD_DIR}" \
    LOCALVERSION=+ kernelrelease)"
[[ "${actual_release}" == "${EXPECTED_RELEASE}" ]] ||
    die "release mismatch: expected ${EXPECTED_RELEASE}, got ${actual_release}"

for output in arch/x86/boot/bzImage System.map Module.symvers; do
    [[ -s "${BUILD_DIR}/${output}" ]] || die "missing build output: ${output}"
done
for symbol in cxl_pa_migrate cxl_stats migrate_folio_sync_offload; do
    grep -qw "${symbol}" "${BUILD_DIR}/Module.symvers" ||
        die "custom export is absent from Module.symvers: ${symbol}"
done

for target in "/boot/vmlinuz-${actual_release}" \
              "/boot/initrd.img-${actual_release}" \
              "/boot/config-${actual_release}" \
              "/boot/System.map-${actual_release}" \
              "/lib/modules/${actual_release}"; do
    [[ ! -e "${target}" && ! -L "${target}" ]] ||
        die "refusing to overwrite an installed kernel artifact: ${target}"
done

if command -v mokutil >/dev/null 2>&1; then
    secure_boot_state="$(LC_ALL=C mokutil --sb-state 2>&1 || true)"
    if grep -qi 'SecureBoot enabled' <<< "${secure_boot_state}"; then
        die "Secure Boot is enabled; arrange authorized kernel/module signing before installation"
    fi
    printf 'Secure Boot check: %s\n' "${secure_boot_state//$'\n'/; }"
else
    warn "mokutil is unavailable; verify that Secure Boot will accept this locally built kernel"
fi

available_boot_kib="$(df -Pk /boot | awk 'NR == 2 { print $4 }')"
if [[ "${available_boot_kib}" =~ ^[0-9]+$ ]] &&
   (( available_boot_kib < 512 * 1024 )); then
    die "less than 512 MiB is free on the /boot filesystem"
fi

printf 'This installs %s but does not change GRUB_DEFAULT or reboot.\n' "${actual_release}"
sudo -v

sudo make -C "${SOURCE_DIR}" O="${BUILD_DIR}" LOCALVERSION=+ modules_install
sudo make -C "${SOURCE_DIR}" O="${BUILD_DIR}" LOCALVERSION=+ install
sudo depmod "${actual_release}"

if [[ -e "/boot/initrd.img-${actual_release}" ]]; then
    sudo update-initramfs -u -k "${actual_release}"
else
    sudo update-initramfs -c -k "${actual_release}"
fi
sudo update-grub

for target in "/boot/vmlinuz-${actual_release}" \
              "/boot/initrd.img-${actual_release}" \
              "/boot/config-${actual_release}" \
              "/boot/System.map-${actual_release}" \
              "/lib/modules/${actual_release}"; do
    [[ -e "${target}" || -L "${target}" ]] || die "installation did not create: ${target}"
done

printf '\nInstalled %s. No reboot was requested.\n' "${actual_release}"
printf 'Keep both source and build directories for the external-module fallback.\n'
printf 'Follow the staged GRUB procedure in kernel/README.md before making it persistent.\n'
