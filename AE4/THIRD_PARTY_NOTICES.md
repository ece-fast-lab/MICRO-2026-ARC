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
| NumPy, Matplotlib, scikit-learn, and joblib | Not included. These Python packages are used by optional offline analysis/training under their respective licenses. Only Matplotlib is needed for the normal Figure 11 plot. |
| `sw/ml/reference_trials` | Derived numeric trial/configuration records from the authors' experiment history; no benchmark binaries or graph datasets are included. Confirm publication authorization for experimental data before public release. |

Keep all original source headers and license texts when redistributing the
artifact.
