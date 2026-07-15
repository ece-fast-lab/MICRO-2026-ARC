# MICRO-2026-ARC

MICRO 2026 Artifact Evaluation materials.

The same portable SPR1 baseline setup and CHMU benchmark workflow is included
in each artifact directory:

| Artifact | Reviewer guide |
|---|---|
| AE2 | [AE2/README.md](AE2/README.md) |
| AE3 | [AE3/README.md](AE3/README.md) |
| AE4 | [AE4/README.md](AE4/README.md) |

For example:

```bash
cd AE2
bash set_default/setup_default.sh all
```

Replace `AE2` with `AE3` or `AE4` for the corresponding artifact. All three
entry points intentionally share one host-wide lock because they control the
same SPR1 PCI device, modules, cgroup, and CPU/NUMA state.
