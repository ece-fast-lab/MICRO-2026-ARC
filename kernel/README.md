# MICRO 2026 ARC custom kernel

This directory reconstructs the SPR1 kernel from Linux v6.11, the ARC patch, and the installed configuration.
The expected release is `6.11.0-mig-offload+`.

Kernel installation is a one-time administrator task.
Skip this document when SPR1 already runs the expected kernel because AE2–AE4 use validated prebuilt modules.

## Reproduction inputs

| Item | Pinned value |
|---|---|
| Vanilla base | [Linux `v6.11`](https://github.com/torvalds/linux/tree/v6.11) |
| Upstream commit | [`98f7e32f20d28ec452afb208f9cffc08448a2652`](https://github.com/torvalds/linux/commit/98f7e32f20d28ec452afb208f9cffc08448a2652) |
| Original ARC source HEAD | `5058499dedff9832af6cb52f36caf2493ecd6bda`, including the captured `mm/damon/paddr.c` worktree update |
| Kernel release | `6.11.0-mig-offload+` |
| Patch SHA-256 | `314eb2f6c16cf2136e0a4df0fefaa2628aae5d7182d8bc9571e91021e483e19d` |
| Config SHA-256 | `20745c0843e064bd76e53bbae0a35e10fe7cb23ba050e255099448a0907e2919` |
| Applied-source manifest SHA-256 | `e30049bc30a5ebec20c1a2651229c048340bee8916779be0fbc38f9844a86ebd` |
| Installed image SHA-256 | `367c0b7251be2cd9f3029a49341d68120e4357282cd60f5af2380e0cc3835f49` |
| Installed `System.map` SHA-256 | `883be01d8e73807d403aeb00ac090151e677f3948768177dc25250e20920c912` |
| Known-good build host | Ubuntu 24.04.3, GCC 13.3.0, binutils 2.42 |

The installed `.config`, `bzImage`, and `System.map` matched the original source tree byte for byte.
A new image may have a different hash because timestamps, build paths, signing keys, and toolchain details enter the output.
The scripts verify the patch, configuration, release name, and required ABI.

| Path | Purpose |
|---|---|
| `configs/config-6.11.0-mig-offload+` | Installed kernel configuration |
| `patches/0001-micro-arc-mig-offload.patch` | ARC changes relative to Linux v6.11 |
| `scripts/prepare_source.sh` | Clone, pin, verify, and patch the source |
| `scripts/build_kernel.sh` | Build out of tree and check the ABI |
| `scripts/install_kernel.sh` | Install without changing the GRUB default or rebooting |
| `scripts/verify_kernel.sh` | Check the kernel and platform after reboot |
| `SHA256SUMS` | Input integrity hashes |
| `SOURCE_SHA256SUMS` | Applied-source integrity hashes |

## 1. Install build packages

The known-good build host runs Ubuntu 24.04.

```bash
sudo apt-get update
sudo apt-get install build-essential bc bison flex libssl-dev libelf-dev \
  libncurses-dev dwarves cpio rsync zstd openssl git mokutil kmod \
  initramfs-tools grub2-common debianutils
```

Reserve at least 40 GiB for the source and out-of-tree build.
The upstream [kernel build guide](https://www.kernel.org/doc/html/latest/admin-guide/quickly-build-trimmed-linux.html) provides additional background.

## 2. Prepare the source

Run the preparation script from the MICRO-2026-ARC repository.
The destination directory must not exist.

```bash
bash kernel/scripts/prepare_source.sh /path/to/linux-6.11-arc
```

The script clones the official `v6.11` tag, verifies its commit, checks the supplied hashes, and applies the ARC patch.
The patch remains staged against `v6.11` for review with `git diff v6.11`.

## 3. Build the kernel

Build into a separate directory.

```bash
JOBS="$(nproc)" bash kernel/scripts/build_kernel.sh \
  /path/to/linux-6.11-arc \
  /path/to/linux-6.11-arc-build
```

The script installs the supplied config and runs `olddefconfig`.
It requires `CONFIG_M5=y`, the migration options, and the CXL options used by ARC.
Only a toolchain-derived change to `CONFIG_CC_VERSION_TEXT` is accepted.
`LOCALVERSION=+` and the patched `EXTRAVERSION=-mig-offload` produce the expected release name.

The build must produce `bzImage`, `System.map`, `Module.symvers`, and these exported symbols:

```text
cxl_pa_migrate
cxl_stats
migrate_folio_sync_offload
```

`reset_cxl_stats()` and `print_cxl_stats()` are header-only helpers and do not appear in `Module.symvers`.
GCC 13.3 reports known warnings in the captured custom sources, but the verified objects compile successfully.

The configuration generates a local module-signing key.
Keep the build directory for external-module builds, but never publish `certs/signing_key.pem` or another private key.

## 4. Install the kernel

Keep a known-good bootable kernel installed before continuing.
Skip installation when `/boot/vmlinuz-6.11.0-mig-offload+` and its module tree already exist.

```bash
bash kernel/scripts/install_kernel.sh \
  /path/to/linux-6.11-arc \
  /path/to/linux-6.11-arc-build
```

The installer does not overwrite an existing image, initrd, or module tree.
It also stops when Secure Boot is enabled and the new kernel is unsigned.
It installs the modules and image and regenerates the initrd and GRUB menu.
It does not change `GRUB_DEFAULT` or reboot the host.

If installation is interrupted, inspect the partial files from a fallback kernel.
Remove or move them only after confirming that the running kernel does not use them.
Then rerun the installer.

Keep both the source and build directories.
See the [external modules guide](https://www.kernel.org/doc/html/latest/kbuild/modules.html) for the Kbuild interface.

## 5. Test the GRUB entry

Do not use a numeric GRUB entry because menu positions change after kernel updates.
Back up the current configuration and inspect the generated titles.

```bash
sudo cp -a /etc/default/grub "/etc/default/grub.before-micro-arc.$(date +%Y%m%d-%H%M%S)"
sudo grep -E "^submenu |^menuentry " /boot/grub/grub.cfg
```

Record the running release, create a GRUB drop-in directory, and edit the ARC configuration.

```bash
uname -r
sudo install -d -m 0755 /etc/default/grub.d
sudoedit /etc/default/grub.d/99-micro-2026-arc.cfg
```

Use the current kernel as the fallback and set the required command line.
Replace `<CURRENT_RELEASE>` with the output of `uname -r`.

```text
GRUB_DEFAULT="Advanced options for GNU/Linux>GNU/Linux, with Linux <CURRENT_RELEASE>"
GRUB_CMDLINE_LINUX_DEFAULT='quiet intel_iommu=on,sm_on iommu=pt no5lvl splash efi=nosoftreserve memmap=124G\$0x180000000'
```

Keep the backslash before `$` in the GRUB defaults file.
After boot, `/proc/cmdline` must contain `memmap=124G$0x180000000` without the backslash.

Confirm console or BMC recovery access before rebooting.
Then select the ARC kernel for one boot.

```bash
sudo update-grub
TARGET_ENTRY='Advanced options for GNU/Linux>GNU/Linux, with Linux 6.11.0-mig-offload+'
sudo grub-reboot "${TARGET_ENTRY}"
sudo grub-editenv list
sudo reboot
```

`grub-editenv list` should show the requested `next_entry`.
Do not use this method when GRUB cannot update its environment block, including some LVM and MDRAID layouts.

Verify the host after reconnecting.

```bash
bash kernel/scripts/verify_kernel.sh
```

After verification passes, make the ARC entry persistent in the same GRUB drop-in.

```text
GRUB_DEFAULT="Advanced options for GNU/Linux>GNU/Linux, with Linux 6.11.0-mig-offload+"
```

Apply the change.

```bash
sudo update-grub
```

The final command line must contain:

```text
intel_iommu=on,sm_on iommu=pt no5lvl efi=nosoftreserve memmap=124G$0x180000000
```

Verification also checks CPUs `0-31` on NUMA node 0, memory-only NUMA node 1, NUMA demotion, and the three custom symbols.

## Recovery

Select the retained fallback kernel from **Advanced options for GNU/Linux** if the ARC kernel does not boot.
Restore the timestamped GRUB backup or remove the ARC drop-in.
Run `sudo update-grub` before rebooting again.

## Patch scope and M5 lineage

The patch changes 15 paths under the kernel `Makefile`, `drivers/m5`, migration headers, `mm/damon`, and the Linux memory-management subsystem.
The complete list is recorded in `SOURCE_SHA256SUMS` and the patch itself.

The migration implementation derives in part from the public [ASPLOS 2025 M5 kernel materials](https://github.com/ece-fast-lab/ASPLOS-2025-M5/tree/96da2c2b26c39f59987a145e61ab944b4c87f536/kernels).
M5's standalone [`6.11_changes/paddr.c`](https://github.com/ece-fast-lab/ASPLOS-2025-M5/blob/96da2c2b26c39f59987a145e61ab944b4c87f536/kernels/6.11_changes/paddr.c) implements a different DAMON-PAC experiment.
The supplied patch therefore captures the verified ARC source instead of combining M5 files during installation.

## License

The repository MIT license does not relicense Linux or M5-derived code.
See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md), [`COPYING`](COPYING), and the files under `LICENSES/`.
