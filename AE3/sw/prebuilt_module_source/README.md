# Source Snapshot for the Bundled SPR1 Kernel Modules

This directory contains the source and Makefiles used for the two bundled SPR1 kernel modules.
These files are retained for provenance.
Normal setup loads `sw/kmod_pgmigrate/page_migrate.ko` and `sw/kmod_pac_ofw_buf/pac_ofw_buf.ko`.
Fallback builds use the maintained sources in those module directories.

| Module | Module SHA-256 | ELF Build ID | Source SHA-256 |
|---|---|---|---|
| `page_migrate.ko` | `92d473a1f42e8313c51212f52b16a7718c23360bb7de4a345f5770ca8e6736e6` | `e3bcbf8e3fae6afc36b19b3e99561cc9fd8b0b97` | `90db753c31dfc72ee177bb462ef2e44035ffad2d9e0ef667d34d26ed63afa63c` |
| `pac_ofw_buf.ko` | `328843d7886305b4fa95d2209398d42a75c9ebff794ade213b84bb8a43a52d8d` | `fcabe0befe37b63d8fccdf21dfc629a1a5c84d0c` | `d04b9ae76970f21b4394ba646650d4696c3355124f58be928aab8d56006af39c` |

Both modules have vermagic `6.11.0-mig-offload+`.
The prebuilt overflow module fixes its allocation node to NUMA node 0.
Setup accepts the bundled pair only for the original SPR1 node layout.
Absolute paths in the DWARF sections record the original build location and are not runtime dependencies.
