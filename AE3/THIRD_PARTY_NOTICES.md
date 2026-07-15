# Third-party and component notices

The repository-level MIT license does not replace licenses or notices embedded
in copied components.

| Component | Notice |
|---|---|
| `sw/pcimem` | Copyright Bill Farrow and Jan-Derk Bakker; GPL version 2 or, at the recipient's option, any later version. The license text is retained as `sw/pcimem/COPYING`. |
| `sw/kmod_pgmigrate/page_migrate.c` | Copyright 2024 Jiyuan Zhang; GPL version 2, as stated in the source header. |
| `sw/kmod_pac_ofw_buf` | The source declares `MODULE_LICENSE("GPL")`, but the copied file contains no complete copyright/license grant. Confirm redistribution authorization before public release. |
| `sw/migration_manager` and benchmark runners | The copied source has no component-level license notice. Confirm that the repository owner has authority to distribute it under the intended license before public release. |
| FPGA ZIP/CDF/POF material | Generated hardware images may be subject to tool, IP-core, or project-specific terms. Confirm redistribution authorization before public release. |
| SPEC CPU2017 | Not included. Reviewers must use a separately licensed installation. |
| GAPBS and graph datasets | Not included. Reviewers must provide their installation and datasets under the applicable licenses. |
| DAMON user-space tool (`damo`) | Not included. AE3 uses the existing SPR1 installation linked by [ASPLOS-2025-M5 `sw/damo`](https://github.com/ece-fast-lab/ASPLOS-2025-M5/tree/main/sw/damo); its upstream licensing applies. |

Keep all original source headers and license texts when redistributing the
artifact.
