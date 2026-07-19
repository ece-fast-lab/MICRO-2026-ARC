#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
KERNEL_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd -P)"
PATCH_FILE="${KERNEL_DIR}/patches/0001-micro-arc-mig-offload.patch"
CONFIG_FILE="${KERNEL_DIR}/configs/config-6.11.0-mig-offload+"
SOURCE_MANIFEST="${KERNEL_DIR}/SOURCE_SHA256SUMS"
UPSTREAM_COMMIT="98f7e32f20d28ec452afb208f9cffc08448a2652"
EXPECTED_CONFIG_SHA256="20745c0843e064bd76e53bbae0a35e10fe7cb23ba050e255099448a0907e2919"
EXPECTED_RELEASE="6.11.0-mig-offload+"
BUILD_MARKER=".micro-arc-kernel-build"

usage() {
    printf 'Usage: [JOBS=N] bash %s SOURCE_DIR [BUILD_DIR]\n' "${BASH_SOURCE[0]}" >&2
}

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

warn() {
    printf 'WARNING: %s\n' "$*" >&2
}

if [[ $# -lt 1 || $# -gt 2 ]]; then
    usage
    exit 2
fi

for command_name in df git make nproc sha256sum; do
    command -v "${command_name}" >/dev/null 2>&1 ||
        die "required command is not installed: ${command_name}"
done

SOURCE_DIR="$(cd -- "$1" 2>/dev/null && pwd -P)" ||
    die "source directory does not exist: $1"
BUILD_INPUT="${2:-${SOURCE_DIR}-build}"
JOBS="${JOBS:-$(nproc --all)}"
[[ "${JOBS}" =~ ^[1-9][0-9]*$ ]] || die "JOBS must be a positive integer"

[[ -f "${SOURCE_DIR}/Makefile" && -d "${SOURCE_DIR}/.git" ]] ||
    die "source must be the Git tree produced by prepare_source.sh"

actual_commit="$(git -C "${SOURCE_DIR}" rev-parse HEAD)"
[[ "${actual_commit}" == "${UPSTREAM_COMMIT}" ]] ||
    die "source HEAD must remain official v6.11 (${UPSTREAM_COMMIT}); got ${actual_commit}"
git -C "${SOURCE_DIR}" apply --reverse --check --whitespace=nowarn "${PATCH_FILE}" ||
    die "the complete MICRO ARC patch is not present in the source tree"
(
    cd -- "${SOURCE_DIR}"
    sha256sum --check --status "${SOURCE_MANIFEST}"
) || die "patched source files do not match the captured ARC source"

expected_path_count="$(wc -l < "${SOURCE_MANIFEST}")"
actual_path_count=0
while IFS= read -r status_line; do
    [[ -n "${status_line}" ]] || continue
    changed_path="${status_line:3}"
    awk -v path="${changed_path}" '$2 == path { found = 1 } END { exit !found }' \
        "${SOURCE_MANIFEST}" || die "unexpected source-tree change: ${changed_path}"
    actual_path_count=$((actual_path_count + 1))
done < <(git -C "${SOURCE_DIR}" status --porcelain=v1 --untracked-files=all)
[[ "${actual_path_count}" -eq "${expected_path_count}" ]] ||
    die "source status contains ${actual_path_count} paths; expected ${expected_path_count}"

if [[ -e "${BUILD_INPUT}" && ! -d "${BUILD_INPUT}" ]]; then
    die "build path exists but is not a directory: ${BUILD_INPUT}"
fi
mkdir -p -- "${BUILD_INPUT}"
BUILD_DIR="$(cd -- "${BUILD_INPUT}" && pwd -P)"
[[ "${BUILD_DIR}" != "${SOURCE_DIR}" ]] ||
    die "an out-of-tree build directory is required"

if [[ -n "$(find "${BUILD_DIR}" -mindepth 1 -maxdepth 1 -print -quit)" &&
      ! -f "${BUILD_DIR}/${BUILD_MARKER}" ]]; then
    die "refusing to use a nonempty unmarked build directory: ${BUILD_DIR}"
fi
: > "${BUILD_DIR}/${BUILD_MARKER}"

available_kib="$(df -Pk "${BUILD_DIR}" | awk 'NR == 2 { print $4 }')"
if [[ "${available_kib}" =~ ^[0-9]+$ ]] && (( available_kib < 40 * 1024 * 1024 )); then
    warn "less than 40 GiB is free on the build filesystem; a full build may run out of space"
fi

printf '[1/4] Installing the exact known-good configuration...\n'
cp -- "${CONFIG_FILE}" "${BUILD_DIR}/.config"
printf '%s  %s\n' "${EXPECTED_CONFIG_SHA256}" "${BUILD_DIR}/.config" |
    sha256sum --check --status || die "copied config hash does not match"

printf '[2/4] Resolving config defaults and release name...\n'
make -C "${SOURCE_DIR}" O="${BUILD_DIR}" LOCALVERSION=+ olddefconfig
actual_config_sha256="$(sha256sum "${BUILD_DIR}/.config" | awk '{ print $1 }')"
if [[ "${actual_config_sha256}" != "${EXPECTED_CONFIG_SHA256}" ]]; then
    if diff -q \
        <(grep -v '^CONFIG_CC_VERSION_TEXT=' "${CONFIG_FILE}") \
        <(grep -v '^CONFIG_CC_VERSION_TEXT=' "${BUILD_DIR}/.config") >/dev/null; then
        warn "olddefconfig updated CONFIG_CC_VERSION_TEXT (generated hash: ${actual_config_sha256})"
    else
        "${SOURCE_DIR}/scripts/diffconfig" "${CONFIG_FILE}" "${BUILD_DIR}/.config" >&2 || true
        die "olddefconfig changed functional configuration beyond CONFIG_CC_VERSION_TEXT"
    fi
fi

for config_symbol in CONFIG_M5=y CONFIG_DAMON_PADDR=y CONFIG_MIGRATION=y \
                     CONFIG_CXL_BUS=y CONFIG_CXL_PORT=y CONFIG_MODVERSIONS=y; do
    grep -qxF "${config_symbol}" "${BUILD_DIR}/.config" ||
        die "required configuration is absent: ${config_symbol}"
done

actual_release="$(make -s -C "${SOURCE_DIR}" O="${BUILD_DIR}" \
    LOCALVERSION=+ kernelrelease)"
[[ "${actual_release}" == "${EXPECTED_RELEASE}" ]] ||
    die "release mismatch: expected ${EXPECTED_RELEASE}, got ${actual_release}"

gcc_version="$(gcc -dumpfullversion -dumpversion 2>/dev/null || true)"
[[ "${gcc_version}" == "13.3.0" ]] ||
    warn "known-good build used GCC 13.3.0; this host reports ${gcc_version:-unknown}"

printf '[3/4] Building %s with %s job(s)...\n' "${actual_release}" "${JOBS}"
make -C "${SOURCE_DIR}" O="${BUILD_DIR}" LOCALVERSION=+ -j "${JOBS}"

printf '[4/4] Verifying build outputs and custom exports...\n'
for output in arch/x86/boot/bzImage System.map Module.symvers; do
    [[ -s "${BUILD_DIR}/${output}" ]] || die "missing build output: ${output}"
done
for symbol in cxl_pa_migrate cxl_stats migrate_folio_sync_offload; do
    grep -qw "${symbol}" "${BUILD_DIR}/Module.symvers" ||
        die "custom export is absent from Module.symvers: ${symbol}"
done

printf '\nBuild complete\n'
printf '  release: %s\n' "${actual_release}"
printf '  image:   %s/arch/x86/boot/bzImage\n' "${BUILD_DIR}"
printf '  config:  %s/.config\n' "${BUILD_DIR}"
printf '\nNext: bash %s/scripts/install_kernel.sh %q %q\n' \
    "${KERNEL_DIR}" "${SOURCE_DIR}" "${BUILD_DIR}"
