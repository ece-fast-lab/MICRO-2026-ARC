# Third-party and component notices

The repository-level MIT license does not replace licenses or notices embedded in copied components.

| Component | Notice |
|---|---|
| `cxl-tracer` (submodule) | Upstream project [ece-fast-lab/cxl-tracer](https://github.com/ece-fast-lab/cxl-tracer), referenced as a submodule pinned to the `MICRO_2026_ARC_artifact` branch. It is not vendored into this repository and carries its own license. Users are asked to cite the CXL-Tracer CAL paper (doi `10.1109/LCA.2026.3673181`); see the submodule's `README.md`. The bundled `cxl-tracer.qar` FPGA project archive may be subject to tool, IP-core, or project-specific terms — confirm redistribution authorization before public release. |
| `trace_analysis/parser` | Trace parser (`src/`, `pdf_parser/`) vendored from the authors' analysis repository so `regenerate.sh` is self-contained. The copied source has no component-level license notice. Confirm that the repository owner has authority to distribute it under the intended license before public release. |
| `trace_analysis/traces/*.csv.gz` | Windowed per-page access counts derived from GAPBS and SPEC CPU2017 runs. The raw `.bin` traces and the workloads themselves are not included. Confirm redistribution authorization for the SPEC-derived inputs before public release. |
| `trace_analysis/figure*/figure_*.py` | Plot scripts have no component-level license notice. Confirm that the repository owner has authority to distribute them under the intended license before public release. |
| matplotlib, numpy, pandas | Not included. Reviewers must install these under their own licenses (all permissive BSD-style). |
| SPEC CPU2017 | Not included. The `spec_502_gcc_r_c8` inputs are derived counts; the benchmark itself requires a separately licensed installation. |
| GAPBS and graph datasets | Not included. The `gapbs_*_twitter` inputs are derived counts; reviewers must provide the benchmark and datasets under the applicable licenses. |

Keep all original source headers and license texts when redistributing the artifact.
