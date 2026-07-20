# Third-Party and Component Notices

The repository MIT license does not replace licenses or notices included with individual components.

## `sw/pcimem`

The source names Bill Farrow and Jan-Derk Bakker as copyright holders.
It is licensed under GPL version 2 or any later version.
The license text is retained in `sw/pcimem/COPYING`.

## Kernel modules

`sw/kmod_pgmigrate` and the bundled `page_migrate.ko` identify GPL version 2.
The source names Jiyuan Zhang as the 2024 copyright holder.

`sw/kmod_pac_ofw_buf` and the bundled `pac_ofw_buf.ko` declare `MODULE_LICENSE("GPL")`.
The copied `pac_ofw_buf` source does not contain a complete copyright or license grant.
Confirm redistribution authorization before public release.

`sw/prebuilt_module_source` contains the sources that match the bundled modules.
Fallback builds use the maintained sources in the two module directories.

## Migration software

`sw/migration_manager` and the benchmark runners have no component-level license notice.
Confirm authority to distribute them under the intended repository license.

## FPGA files

The ZIP, CDF, and POF files may be subject to FPGA tool, IP-core, or project-specific terms.
Confirm redistribution authorization before public release.

## External benchmarks and tools

SPEC CPU2017 is not included.
Reviewers must provide a licensed installation.

GAPBS binaries and graph data are not included.
Reviewers must provide them under their applicable licenses.

The DAMON user-space tool (`damo`) is not included.
AE3 uses the existing SPR1 installation described by the [ASPLOS-2025-M5 `damo` directory](https://github.com/ece-fast-lab/ASPLOS-2025-M5/tree/main/sw/damo).
The upstream `damo` license applies.

Keep original source headers and license texts when redistributing the artifact.
