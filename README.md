# ARC: Adaptive Reconfigurable CXL Hotness Monitoring

This repository contains the artifact for the MICRO 2026 paper **“ARC: Adaptive Reconfigurable CXL Hotness Monitoring.”**
It includes the custom RTL, FPGA images, host software, experiment scripts, and plotting tools used in the paper.

## Artifact contents

| Directory | Experiment |
|---|---|
| [`AE1/`](AE1/) | Figures 2, 5, 7: per-page access-distribution and hot-page analysis from bundled CXL traces. Software-only (`python3`). |
| [`AE2/`](AE2/) | Figure 4: memory usage and migration traffic for SPEC CPU2017 `gcc`. |
| [`AE3/`](AE3/) | Figure 3: CXL-only, AutoNUMA, DAMON, CHMU-Cache, and CHMU-CMS comparison. |
| [`AE4/`](AE4/) | Figure 11: static CHMU policies and ARC adaptive selection. |
| [`kernel/`](kernel/) | Optional reconstruction of the `6.11.0-mig-offload+` kernel. |
| [`rtl/`](rtl/) | Custom ARC SystemVerilog sources. |

AE2, AE3, and AE4 are the hardware workflows in this checkout. AE1 is a
software-only trace-analysis artifact and needs no SPR1 host or FPGA; it bundles
the derived CSVs and references the CXL-Tracer collection framework as a
submodule, initialized with `git submodule update --init --recursive`.

## Requirements

AE1 is software-only. It needs only `python3` with Matplotlib, NumPy, and
pandas, and none of the hardware, host, or benchmark requirements below. The
rest of this section applies to AE2, AE3, and AE4.

### Hardware

- Intel Xeon Scalable host with CXL support.
- Intel Agilex 7 I-Series FPGA Development Kit configured as a CXL Type-2 device.
- Access to the FPGA programming server and JTAG cable.
- Authorization to power-cycle SPR1 after FPGA programming.
- Exclusive access to SPR1 during setup and measurement.

The scripts change system-wide CPU, NUMA, swap, PCI, cgroup, MSR, and FPGA state.
BMC credentials and power-cycle commands are provided separately by the system operator.

### Host software

SPR1 must run Ubuntu 24.04 with the custom `6.11.0-mig-offload+` kernel.
The kernel command line must contain:

```text
intel_iommu=on,sm_on iommu=pt no5lvl efi=nosoftreserve memmap=124G$0x180000000
```

The host also requires Bash, CMake, Make, GCC/G++, libnuma, PCI utilities, numactl, numastat, perf, msr-tools, PQoS, cgroup v2, and Python 3.
NumPy and Matplotlib are required for plotting.
Scikit-learn and joblib are required only for optional AE4 retraining.

Run setup and benchmarks from the reviewer account.
Do not use `sudo -i` or place `sudo` before an entire artifact command.
The scripts request elevated privileges when needed.

### Benchmarks and data

The following licensed software and data are not distributed:

- SPEC CPU2017 for AE2 and optional AE3/AE4 SPEC runs.
- GAPBS and the Twitter graph for the primary AE3 and AE4 runs.
- The Web graph for optional GAPBS runs.
- DAMON user tools (`damo`) for the AE3 comparison.

Set the local paths in the applicable file before running an experiment:

```text
AE2/sw/config/benchmark_paths.env
AE3/sw/config/benchmark_paths.env
AE4/sw/config/benchmark_paths.env
```

Reserve about 2 GB for FPGA images and a clean result set.
External benchmarks and graph data require additional storage.
Initial setup takes about one hour, and the primary experiments take about ten hours in total.

## Common setup

### 1. Clone the repository

Clone the repository on SPR1 and the FPGA programming server when they do not share a filesystem.

```bash
git clone https://github.com/ece-fast-lab/MICRO-2026-ARC.git
cd MICRO-2026-ARC
```

### 2. Program the SPL1 image

AE2, AE3, and AE4 use the same SPL1 image for their primary experiments.
The example below uses the copy under AE2.

```bash
cd MICRO-2026-ARC/AE2
unzip -o program_script/chmu_ae_merge_SPL1.zip -d program_script
bash program_script/update_cdf_paths.sh
bash program_script/program_spr1.sh chmu_ae_merge_SPL1.cdf
```

Ask the system operator to power-cycle SPR1 after programming.
Wait for SPR1 to boot before continuing.
The SPL1 image can be reused across AE2, AE3, and AE4 while it remains loaded.

### 3. Verify SPR1

```bash
uname -r
numactl -H
```

The expected kernel is `6.11.0-mig-offload+`.
NUMA node 0 must contain CPUs `0-31`, and NUMA node 1 must be memory-only CXL memory.

### 4. Configure the host

Run the setup script in the AE directory that you will use.

```bash
cd MICRO-2026-ARC/AE2
bash set_default/setup_default.sh all
```

Replace `AE2` with `AE3` or `AE4` for the corresponding experiment.
The setup checks the platform, builds the host tools, loads the bundled modules, and applies the CPU, NUMA, and CHMU settings.

## Experiments

### AE1: Figures 2, 5, 7

AE1 is independent of the Common setup above: it needs no FPGA, SPR1 host, or
custom kernel. It renders the per-page access-distribution and hot-page
analysis figures from the CXL traces bundled under `AE1/trace_analysis/traces/`.

```bash
cd MICRO-2026-ARC/AE1
bash trace_analysis/figure2/run_fig2.sh
bash trace_analysis/figure5/run_fig5.sh
bash trace_analysis/figure7/run_fig7.sh
```

Each runner writes its `generated_fig*.png` panels beside the shipped
`expected_fig*.png` references. The traces were captured with the CXL-Tracer
framework included as a submodule; collecting them is out of scope for this
artifact. See [`AE1/README.md`](AE1/README.md) for the figure descriptions and
the optional path that rebuilds the bundled CSVs from the raw traces.

### AE2: Figure 4

AE2 runs eight copies of SPEC CPU2017 `gcc` with CHMU-Cache at thresholds 32 and 96.

```bash
cd MICRO-2026-ARC/AE2
./sw/build_option_th32/run_fig4_th32.sh all yes --skip-plot
./sw/build_option_th96/run_fig4_th96.sh all yes --skip-plot
```

Generate the plots after data collection.
See [`AE2/README.md`](AE2/README.md) for the plotting commands and expected files.

### AE3: Figure 3

The primary AE3 path uses GAPBS PageRank on the Twitter graph.
It runs the CXL-only baseline, AutoNUMA, DAMON, and both CHMU designs at four thresholds.

```bash
cd MICRO-2026-ARC/AE3
bash sw/fig3/run_fig3_all_yes.sh pr_tw
```

Use the same command with `--resume` after an interruption.
See [`AE3/README.md`](AE3/README.md) for plotting and optional workloads.

### AE4: Figure 11

AE4 runs `bc_tw`, `bfs_tw`, and `pr_tw` at threshold 16.
It compares CXL-only, CHMU-Cache, CHMU-CMS, and Adaptive.

```bash
cd MICRO-2026-ARC/AE4
bash sw/fig11/run_all_primary_th16.sh
```

Use the same command with `--resume` after an interruption.
See [`AE4/README.md`](AE4/README.md) for the combined plot and optional retraining.

## Expected results

- AE1 renders Figures 2, 5, and 7 as PNG panels from the bundled traces, with the published `expected_*.png` panels shipped alongside for reference.
- AE2 produces local-memory, CXL-memory, and migration-traffic plots for thresholds 32 and 96.
- AE3 reports normalized performance as `CXL-only time / method time` for eleven methods.
- AE4 reports the same normalization for three workloads and their geometric mean.

A normalized value above 1.0 indicates improvement over the CXL-only baseline.
Data collection and plotting are separate so plots can be regenerated without rerunning hardware experiments.

## Optional workflows

- AE1 can rebuild its bundled CSVs from the raw `.bin` traces with `AE1/trace_analysis/regenerate.sh`, using the vendored trace parser.
- AE3 provides additional GAPBS and SPEC workloads, epoch sweeps, and FPGA sampling studies.
- AE4 provides current-system trial collection and GAPBS-only leave-one-benchmark-out retraining.
- The kernel directory provides the optional one-time kernel build and installation procedure.

## Licensing

The repository-level MIT license does not replace licenses attached to copied components.
SPEC CPU2017, GAPBS data, DAMON, Intel FPGA packages, and generated IP retain their own licenses.
See the `THIRD_PARTY_NOTICES.md` files under [`AE1/`](AE1/THIRD_PARTY_NOTICES.md), `AE2/`, `AE3/`, `AE4/`, [`kernel/`](kernel/THIRD_PARTY_NOTICES.md), and [`rtl/`](rtl/THIRD_PARTY_NOTICES.md).
