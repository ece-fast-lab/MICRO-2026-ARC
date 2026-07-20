# AE3 – Page-Migration Performance Comparison (Figure 3)

AE3 reproduces Figure 3 with GAPBS PageRank on the Twitter graph (`pr_tw`).

## Experiment summary

| Item | Configuration |
|---|---|
| FPGA image | `chmu_ae_merge_SPL1` |
| Workload | GAPBS `pr_tw` |
| Comparison | Baseline, ANB, DAMON, CHMU-Cache, and CHMU-CMS |
| Thresholds | 16, 32, 64, and 96 for Cache and CMS |
| Main output | `figure3_normalized_performance.{png,pdf}` |

## Prerequisites

Use the dedicated SPR1 server with exclusive access during setup and measurement.
Run every command from the reviewer account, not from `sudo -i`.
The scripts request `sudo` only for privileged host controls.

SPR1 must run the `6.11.0-mig-offload+` kernel with two visible NUMA nodes.

```text
intel_iommu=on,sm_on iommu=pt no5lvl efi=nosoftreserve memmap=124G$0x180000000
```

The setup script checks the remaining host packages and the bundled kernel modules.
See the [custom-kernel guide](../kernel/README.md) if SPR1 has not been provisioned.

GAPBS, graph data, SPEC CPU2017, and `damo` are not distributed with this artifact.
ANB is provided by the SPR1 Linux kernel.
NumPy and Matplotlib are required only for plotting.

## 1. Program the SPL1 FPGA image

Run these commands on the FPGA programming server:

```bash
cd MICRO-2026-ARC/AE3
unzip -o program_script/chmu_ae_merge_SPL1.zip -d program_script
bash program_script/update_cdf_paths.sh
bash program_script/program_spr1.sh chmu_ae_merge_SPL1.cdf
```

Power-cycle SPR1 with the command supplied by the system operator.
BMC credentials and the power-cycle command are not included in this repository.

After SPR1 boots, verify the kernel and NUMA topology:

```bash
uname -r
numactl -H
```

## 2. Check benchmark paths

Review the absolute paths in:

```text
AE3/sw/config/benchmark_paths.env
```

The primary run needs `GAPBS_ROOT`, the Twitter graph, `DAMO_BIN`, and `DAMO_CONFIG`.
The optional SPEC runs also need `SPEC_ROOT`, `SPEC_RUNCPU`, and `SPEC_CONFIG`.
See the [ASPLOS-2025-M5 software guide](https://github.com/ece-fast-lab/ASPLOS-2025-M5/blob/main/sw/README.md) for the SPR1 DAMON setup.
The DAMON source link is in its [`sw/damo` directory](https://github.com/ece-fast-lab/ASPLOS-2025-M5/tree/main/sw/damo).

## 3. Configure SPR1

Run setup from the AE3 directory:

```bash
cd MICRO-2026-ARC/AE3
bash set_default/setup_default.sh all
```

Setup checks the platform, builds the four threshold managers, loads the modules, and initializes CHMU.
It does not start a benchmark.

## 4. Collect Figure 3 data

The following command runs all 11 cases for `pr_tw` and writes the result CSV:

```bash
cd MICRO-2026-ARC/AE3
bash sw/fig3/run_fig3_all_yes.sh
```

The script waits 30 seconds between newly executed cases.
It skips plotting so data collection does not depend on Matplotlib.

Use `--resume` after an interruption:

```bash
bash sw/fig3/run_fig3_all_yes.sh --resume
```

Completed cases are reused.
See [Figure 3 reproduction](FIGURE3_REPRODUCTION.md) for individual cases and replacement behavior.

## 5. Plot existing data

Use the Ubuntu system packages on SPR1:

```bash
cd MICRO-2026-ARC/AE3
env PYTHONNOUSERSITE=1 \
  PYTHONPATH=/usr/lib/python3/dist-packages \
  bash sw/fig3/plot_fig3.sh pr_tw
```

This command validates the existing 11 cases and does not rerun GAPBS.

If the system packages are unavailable, create a plotting environment:

```bash
sudo apt install -y python3-venv
python3 -m venv "$HOME/.venvs/micro-2026-arc-plot"
source "$HOME/.venvs/micro-2026-arc-plot/bin/activate"
python3 -m pip install --upgrade pip
python3 -m pip install -r sw/fig3/requirements.txt
bash sw/fig3/plot_fig3.sh pr_tw
deactivate
```

## Expected results

The primary output directory is:

```text
results/figure3/gapbs/pr_twitter/
  figure3_manifest.csv
  figure3_results.csv
  figure3_normalized_performance.png
  figure3_normalized_performance.pdf
  run_metadata.txt
  runs/
```

GAPBS runtime is the geometric mean of `Trial Time` records 6–10 from exactly 10 trials.
The plot reports `baseline_seconds / method_seconds`.
Values above `1.0` indicate a speedup over the CXL-only Baseline.

## Optional experiments

The [detailed Figure 3 guide](FIGURE3_REPRODUCTION.md) documents:

- Other GAPBS workloads and optional SPEC CPU2017 runs.
- The Figure 6 Cache/CMS epoch sweep at threshold 64.
- The SPL1, SPL2, and SPL4 sampling-ratio study.
- Individual cases, result replacement, and troubleshooting.

## Licenses

SPEC CPU2017, GAPBS, graph data, and `damo` retain their own licenses.
See [Third-party and component notices](THIRD_PARTY_NOTICES.md) before redistribution.
