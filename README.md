# MICRO-2026-ARC

MICRO 2026 Artifact Evaluation materials.

The same portable SPR1 baseline setup and CHMU benchmark workflow is included
in each artifact directory:

| Artifact | Reviewer guide |
|---|---|
| Kernel provisioning (optional) | [kernel/README.md](kernel/README.md) |
| AE2 | [AE2/README.md](AE2/README.md) |
| AE3 | [AE3/README.md](AE3/README.md) |
| AE4 | [AE4/README.md](AE4/README.md) |

The kernel directory reconstructs the custom `6.11.0-mig-offload+` host
kernel from official Linux v6.11 plus a pinned patch and exact config. It is a
one-time provisioning path, not part of the normal AE experiment commands.

AE4 normally uses the shipped pretrained configurations. Its optional
current-system retraining path runs five GAPBS workloads for 20 successful
invocations each (100 total) and is documented in
[`AE4/sw/ml/README.md`](AE4/sw/ml/README.md).

For example:

```bash
cd AE2
bash set_default/setup_default.sh all
```

Replace `AE2` with `AE3` or `AE4` for the corresponding artifact. All three
entry points intentionally share one host-wide lock because they control the
same SPR1 PCI device, modules, cgroup, and CPU/NUMA state.

The repository's MIT license does not relicense the Linux/M5-derived material
under `kernel/`; see [`kernel/THIRD_PARTY_NOTICES.md`](kernel/THIRD_PARTY_NOTICES.md).
