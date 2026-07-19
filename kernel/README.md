# MICRO 2026 ARC custom kernel

This directory reconstructs the SPR1 Artifact Evaluation kernel from an
official Linux v6.11 Git checkout plus one reviewable patch and the exact
installed configuration. The expected release is:

```text
6.11.0-mig-offload+
```

Kernel provisioning is an optional, one-time administrator task. A reviewer
using the already provisioned SPR1 machine should **not** rebuild or reboot the
kernel during the normal AE2/AE3/AE4 path; those artifacts use bundled external
modules and first verify their hashes and vermagic.

## Reproduction inputs and provenance

| Item | Pinned value |
|---|---|
| Vanilla base | [Linux `v6.11`](https://github.com/torvalds/linux/tree/v6.11) |
| Upstream commit | [`98f7e32f20d28ec452afb208f9cffc08448a2652`](https://github.com/torvalds/linux/commit/98f7e32f20d28ec452afb208f9cffc08448a2652) |
| Original ARC source HEAD | `5058499dedff9832af6cb52f36caf2493ecd6bda`, plus the captured `mm/damon/paddr.c` worktree update |
| Applied source paths | 15 paths listed in [Patch scope](#patch-scope-and-m5-lineage) |
| Kernel release | `6.11.0-mig-offload+` |
| Patch SHA-256 | `314eb2f6c16cf2136e0a4df0fefaa2628aae5d7182d8bc9571e91021e483e19d` |
| Config SHA-256 | `20745c0843e064bd76e53bbae0a35e10fe7cb23ba050e255099448a0907e2919` |
| Applied-source manifest SHA-256 | `e30049bc30a5ebec20c1a2651229c048340bee8916779be0fbc38f9844a86ebd` |
| Known-good installed image SHA-256 | `367c0b7251be2cd9f3029a49341d68120e4357282cd60f5af2380e0cc3835f49` |
| Known-good installed `System.map` SHA-256 | `883be01d8e73807d403aeb00ac090151e677f3948768177dc25250e20920c912` |
| Known-good build host | Ubuntu 24.04.3, GCC 13.3.0, binutils 2.42 |

The source tree's `.config`, `bzImage`, and `System.map` were compared directly
with `/boot/config-*`, `/boot/vmlinuz-*`, and `/boot/System.map-*` from the
installed target; each pair was byte-identical. The image hash above records
that provenance, but a fresh build is not expected to reproduce the same image
hash because timestamps, build user/host/path, generated module-signing key,
and toolchain details enter the output. The patch, config, release name, and
custom ABI are the reproducible inputs checked by the scripts.

Files in this directory:

```text
configs/config-6.11.0-mig-offload+       exact installed configuration
patches/0001-micro-arc-mig-offload.patch  changes relative to Linux v6.11
scripts/prepare_source.sh                 clone, pin, verify, and apply
scripts/build_kernel.sh                   out-of-tree build and ABI checks
scripts/install_kernel.sh                 guarded install; no GRUB default/reboot
scripts/verify_kernel.sh                  post-reboot kernel/platform checks
SHA256SUMS                                input integrity checks
SOURCE_SHA256SUMS                         applied-source integrity checks
```

## 1. Install build prerequisites

The known-good host is Ubuntu 24.04. Install the packages once:

```bash
sudo apt-get update
sudo apt-get install build-essential bc bison flex libssl-dev libelf-dev \
  libncurses-dev dwarves cpio rsync zstd openssl git mokutil kmod \
  initramfs-tools grub2-common debianutils
```

Allow at least 40 GiB of free space for the checkout and out-of-tree build.
The upstream kernel's concise build guide is also available in the
[Linux documentation](https://www.kernel.org/doc/html/latest/admin-guide/quickly-build-trimmed-linux.html).

## 2. Prepare a vanilla v6.11 tree and apply the ARC diff

Run this from the MICRO-2026-ARC repository. The destination must not exist:

```bash
bash kernel/scripts/prepare_source.sh /path/to/linux-6.11-arc
```

The script clones the official annotated `v6.11` tag, verifies the peeled
commit, checks `kernel/SHA256SUMS`, and applies the patch with
`--whitespace=nowarn`. That option is intentional: the known-good source
contains legacy trailing whitespace, and preserving it keeps the captured
source exact.

The patch is left as visible staged, uncommitted changes relative to `v6.11`.
Staging ensures newly added files are included when an author later regenerates
the diff; review the complete change with `git diff v6.11`. Build output never
enters this tree.

## 3. Build out of tree

```bash
JOBS="$(nproc)" bash kernel/scripts/build_kernel.sh \
  /path/to/linux-6.11-arc \
  /path/to/linux-6.11-arc-build
```

The script verifies and copies the exact config, runs `olddefconfig`, and then
checks `CONFIG_M5=y` and the required migration/CXL options. A change limited
to toolchain-derived `CONFIG_CC_VERSION_TEXT` is reported and accepted; any
other config drift is rejected. The script passes `LOCALVERSION=+` on every
make invocation; together with the patched
`EXTRAVERSION=-mig-offload`, this deterministically produces
`6.11.0-mig-offload+` without relying on Git clean/dirty state.

It then requires `bzImage`, `System.map`, `Module.symvers`, and these real
exported symbols:

```text
cxl_pa_migrate
cxl_stats
migrate_folio_sync_offload
```

`reset_cxl_stats()` and `print_cxl_stats()` are header-only `static inline`
helpers and therefore are not expected in `Module.symvers`.

The captured custom sources emit several existing compiler warnings (including
missing prototypes and a large stack frame in the statistics printer) with
GCC 13.3. They are visible rather than suppressed; the verified objects still
compile successfully.

The config signs all modules with a locally generated key. Keep the build
directory for the AE external-module fallback, but never publish
`certs/signing_key.pem` or any other generated private key.

## 4. Install without changing the boot default

First keep a known-good bootable kernel installed. On a machine where the
target release does not already exist:

```bash
bash kernel/scripts/install_kernel.sh \
  /path/to/linux-6.11-arc \
  /path/to/linux-6.11-arc-build
```

If `/boot/vmlinuz-6.11.0-mig-offload+` and its module tree are already
installed—as on the current SPR1 setup—skip this command and proceed to the
staged GRUB test.

The script refuses to overwrite an existing `/boot` image, initrd, or module
tree. It also refuses an unsigned installation when Secure Boot reports
enabled. It installs modules and the image, regenerates the initrd and GRUB
menu, but deliberately does not modify `GRUB_DEFAULT` and does not reboot.

If installation is interrupted after privileged writes begin, the collision
guard will also refuse a blind rerun. Boot the retained fallback, inspect the
partial `/boot` and `/lib/modules/6.11.0-mig-offload+` artifacts, and have the
administrator move them aside only after confirming that the running kernel
does not depend on them; then rerun the guarded installer.

Keep both source and build directories. Kbuild's external-module interface is
documented in the
[Linux external modules guide](https://www.kernel.org/doc/html/latest/kbuild/modules.html).

## 5. Test the GRUB entry once, then make it persistent

Do not use a numeric default such as `1>14`: menu positions change after a
kernel update. Back up the current settings and inspect the generated titles:

```bash
sudo cp -a /etc/default/grub "/etc/default/grub.before-micro-arc.$(date +%Y%m%d-%H%M%S)"
sudo grep -E "^submenu |^menuentry " /boot/grub/grub.cfg
```

First replace a numeric default with the exact title of the kernel that is
running now, so it remains the persistent fallback during the one-shot test:

```bash
uname -r
sudo install -d -m 0755 /etc/default/grub.d
sudoedit /etc/default/grub.d/99-micro-2026-arc.cfg
```

Put both settings below in that file, replacing `<CURRENT_RELEASE>` with the
output of `uname -r` and confirming the title in `grub.cfg`:

```text
GRUB_DEFAULT="Advanced options for GNU/Linux>GNU/Linux, with Linux <CURRENT_RELEASE>"
GRUB_CMDLINE_LINUX_DEFAULT='quiet intel_iommu=on,sm_on iommu=pt no5lvl splash efi=nosoftreserve memmap=124G\$0x180000000'
```

The backslash before `$` must remain in the GRUB defaults file. After boot,
the resulting `/proc/cmdline` must contain the literal token
`memmap=124G$0x180000000` without the backslash.

Regenerate the menu and select the new entry for one boot only:

Before issuing the reboot, confirm that an authorized operator has console or
BMC recovery access; credentials are intentionally outside this artifact.

```bash
sudo update-grub
TARGET_ENTRY='Advanced options for GNU/Linux>GNU/Linux, with Linux 6.11.0-mig-offload+'
sudo grub-reboot "${TARGET_ENTRY}"
sudo grub-editenv list
sudo reboot
```

`grub-editenv list` should show the requested `next_entry`. The nested title
syntax is documented by the
[GRUB `default` manual](https://www.gnu.org/software/grub/manual/grub/html_node/default.html).
Do not use the one-shot method on storage where GRUB cannot update its
environment block (notably some LVM/MDRAID layouts); follow the site's console
and recovery policy instead.

After reconnecting, verify the kernel before changing the persistent default:

```bash
bash kernel/scripts/verify_kernel.sh
```

Only after that command passes, put this active, uncommented line in the same
GRUB defaults/drop-in file:

```text
GRUB_DEFAULT="Advanced options for GNU/Linux>GNU/Linux, with Linux 6.11.0-mig-offload+"
```

The leading `#` in `#GRUB_DEFAULT=...` would comment the setting out and have
no effect. Apply the persistent choice with:

```bash
sudo update-grub
```

The final SPR1 command line must contain these exact tokens:

```text
intel_iommu=on,sm_on iommu=pt no5lvl efi=nosoftreserve memmap=124G$0x180000000
```

The verification also expects NUMA node 0 to own CPUs `0-31`, node 1 to be
memory-only, the NUMA demotion control to exist, and all three custom exports
to be visible.

## Recovery

If the custom kernel does not boot or verification fails, select the retained
known-good kernel under **Advanced options for GNU/Linux** from the GRUB
console. Restore the timestamped `/etc/default/grub` backup (or remove the ARC
drop-in), run `sudo update-grub`, and diagnose before trying again. The install
script never removes the fallback kernel and never automates a reboot or
Secure Boot changes.

## Patch scope and M5 lineage

The ARC patch contains only these result-affecting paths:

```text
Makefile
drivers/Kconfig
drivers/Makefile
drivers/m5/Kconfig
drivers/m5/Makefile
drivers/m5/cxl_migrate.c
include/linux/cxl_migrate.h
include/linux/migrate.h
include/linux/migrate_mode.h
mm/damon/paddr.c
mm/internal.h
mm/migrate.c
mm/page_alloc.c
mm/rmap.c
mm/vmscan.c
```

The approach and much of the migration code derive from the public
[ASPLOS 2025 M5 kernel materials](https://github.com/ece-fast-lab/ASPLOS-2025-M5/tree/96da2c2b26c39f59987a145e61ab944b4c87f536/kernels).
However, M5's standalone
[`6.11_changes/paddr.c`](https://github.com/ece-fast-lab/ASPLOS-2025-M5/blob/96da2c2b26c39f59987a145e61ab944b4c87f536/kernels/6.11_changes/paddr.c)
implements a different DAMON-PAC experiment and is not a drop-in ARC source.
This artifact therefore captures the verified ARC tree as one patch instead
of asking reviewers to combine M5 files manually.

Private convenience scripts, stale `DAMON_config`, source-control metadata,
self-test snapshot noise, build products, binaries, generated certificates,
and signing keys are deliberately excluded.

For an author updating the kernel later, begin with a tree produced by
`prepare_source.sh`, make only the intended source edits, review `git status`,
and regenerate the patch relative to the pinned tag:

```bash
git diff --binary --full-index v6.11 -- \
  Makefile drivers/Kconfig drivers/Makefile drivers/m5 \
  include/linux/cxl_migrate.h include/linux/migrate.h \
  include/linux/migrate_mode.h mm/damon/paddr.c mm/internal.h \
  mm/migrate.c mm/page_alloc.c mm/rmap.c mm/vmscan.c \
  > /path/to/MICRO-2026-ARC/kernel/patches/0001-micro-arc-mig-offload.patch

source_tree="$PWD"
manifest=/path/to/MICRO-2026-ARC/kernel/SOURCE_SHA256SUMS
mapfile -t source_paths < <(awk '{ print $2 }' "${manifest}")
(
  cd "${source_tree}"
  sha256sum "${source_paths[@]}"
) > "${manifest}.new"
mv "${manifest}.new" "${manifest}"

cd /path/to/MICRO-2026-ARC/kernel
sha256sum patches/0001-micro-arc-mig-offload.patch \
  configs/config-6.11.0-mig-offload+ SOURCE_SHA256SUMS > SHA256SUMS
```

If the patch adds or removes source paths, update the manifest path list as
well. Update the patch and manifest hashes in the provenance table above, then
repeat clean prepare/build validation. Do not refresh the patch from a tree
that contains in-tree build products or generated credentials.

## License

The repository root is MIT-licensed, but that does not relicense the Linux or
M5-derived kernel material. See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md),
[`COPYING`](COPYING), and the accompanying `LICENSES/` texts.
