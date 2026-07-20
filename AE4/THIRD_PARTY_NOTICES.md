# Third-party and component notices

The repository-level MIT license does not replace licenses or notices embedded in copied components.

## `sw/pcimem`

Copyright Bill Farrow and Jan-Derk Bakker.
This component is licensed under GPL version 2 or, at the recipient's option, any later version.
The license text is retained as `sw/pcimem/COPYING`.

## `sw/kmod_pgmigrate`

The source and bundled `page_migrate.ko` identify GPL version 2.
Copyright 2024 Jiyuan Zhang is stated in the source header.
The matching legacy source is preserved in `sw/prebuilt_module_source`.
The adjacent source is a later maintained revision used only for fallback rebuilding.

## `sw/kmod_pac_ofw_buf`

The source and bundled `pac_ofw_buf.ko` declare `MODULE_LICENSE("GPL")`.
The copied source contains no complete copyright or license grant.
The matching legacy source is preserved in `sw/prebuilt_module_source`.
The adjacent source is a later maintained revision used only for fallback rebuilding.
Confirm redistribution authorization before public release.

## `sw/migration_manager` and benchmark runners

The copied source has no component-level license notice.
Confirm that the repository owner has authority to distribute it under the intended license before public release.

## FPGA ZIP, CDF, and POF material

Generated hardware images may be subject to tool, IP-core, or project-specific terms.
Confirm redistribution authorization before public release.

## SPEC CPU2017

SPEC CPU2017 is not included.
Reviewers must use a separately licensed installation.

## GAPBS and graph datasets

GAPBS and its graph datasets are not included.
Reviewers must provide them under the applicable licenses.

## Python packages

NumPy, Matplotlib, scikit-learn, and joblib are not included and retain their own licenses.
NumPy and Matplotlib are required for the normal Figure 11 plot.
Scikit-learn and joblib are required only for optional training.

## `sw/ml/reference_trials`

These files contain derived numeric trial and configuration records from the authors' experiment history.
They do not include benchmark binaries or graph datasets.
Confirm publication authorization for the experimental data before public release.

Keep all original source headers and license texts when redistributing the artifact.
