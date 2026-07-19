#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
KERNEL_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd -P)"
PATCH_FILE="${KERNEL_DIR}/patches/0001-micro-arc-mig-offload.patch"
UPSTREAM_URL="https://github.com/torvalds/linux.git"
UPSTREAM_TAG="v6.11"
UPSTREAM_COMMIT="98f7e32f20d28ec452afb208f9cffc08448a2652"
EXPECTED_BASE_VERSION="6.11.0-mig-offload"
EXPECTED_RELEASE="6.11.0-mig-offload+"

usage() {
    printf 'Usage: bash %s /path/to/new-linux-6.11-arc\n' "${BASH_SOURCE[0]}" >&2
}

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

if [[ $# -ne 1 ]]; then
    usage
    exit 2
fi

for command_name in git make sha256sum; do
    command -v "${command_name}" >/dev/null 2>&1 ||
        die "required command is not installed: ${command_name}"
done

SOURCE_DIR="$1"
[[ ! -e "${SOURCE_DIR}" && ! -L "${SOURCE_DIR}" ]] ||
    die "destination already exists; choose a new path: ${SOURCE_DIR}"

printf '[1/4] Verifying the supplied patch and config snapshots...\n'
(
    cd -- "${KERNEL_DIR}"
    sha256sum --check SHA256SUMS
)

printf '[2/4] Cloning official Linux %s...\n' "${UPSTREAM_TAG}"
git clone --depth 1 --branch "${UPSTREAM_TAG}" "${UPSTREAM_URL}" "${SOURCE_DIR}"

actual_commit="$(git -C "${SOURCE_DIR}" rev-parse HEAD)"
[[ "${actual_commit}" == "${UPSTREAM_COMMIT}" ]] ||
    die "unexpected ${UPSTREAM_TAG} commit: ${actual_commit}"

printf '[3/4] Applying the MICRO ARC patch...\n'
git -C "${SOURCE_DIR}" apply --check --index --whitespace=nowarn "${PATCH_FILE}"
git -C "${SOURCE_DIR}" apply --index --whitespace=nowarn "${PATCH_FILE}"

# Reverse-checking is a concise assertion that the complete patch is present.
git -C "${SOURCE_DIR}" apply --reverse --check --whitespace=nowarn "${PATCH_FILE}"
(
    cd -- "${SOURCE_DIR}"
    sha256sum --check "${KERNEL_DIR}/SOURCE_SHA256SUMS"
)

printf '[4/4] Checking the patched base version...\n'
actual_base_version="$(make -s -C "${SOURCE_DIR}" kernelversion)"
[[ "${actual_base_version}" == "${EXPECTED_BASE_VERSION}" ]] ||
    die "version mismatch: expected ${EXPECTED_BASE_VERSION}, got ${actual_base_version}"

printf '\nPrepared source: %s\n' "$(cd -- "${SOURCE_DIR}" && pwd -P)"
printf 'Base commit:     %s\n' "${actual_commit}"
printf 'Build release:   %s (with LOCALVERSION=+)\n' "${EXPECTED_RELEASE}"
printf '\nNext: bash %s/scripts/build_kernel.sh %q %q\n' \
    "${KERNEL_DIR}" "${SOURCE_DIR}" "${SOURCE_DIR}-build"
