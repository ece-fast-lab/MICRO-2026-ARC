# AE4 – Adaptive Cache/CMS Performance (Figure 11)

AE4 reproduces Figure 11 for GAPBS `bc_tw`, `bfs_tw`, and `pr_tw`. It compares CXL-only, CHMU-Cache, CHMU-CMS, and Adaptive policies at threshold 16.

## Artifact at a glance

| Item | Reviewer configuration |
|---|---|
| Target | Figure 11 |
| Workloads | `bc_tw`, `bfs_tw`, `pr_tw` |
| FPGA image | `chmu_ae_merge_SPL1` |
| Methods | CXL-only, CHMU-Cache, CHMU-CMS, Adaptive |
| Adaptive configuration | Supplied suite-isolated LOBO cfg |
| Output | Three workloads and `GeoMean` in one PNG/PDF |

## Prerequisites

- An AE host with the CHMU FPGA card and access to the FPGA programming server
- Custom kernel `6.11.0-mig-offload+`
- Kernel command line shown in the [custom-kernel guide](../kernel/README.md)
- GAPBS binaries and the Twitter graph dataset
- A working custom `CHMU_PERF_BIN`
- A reviewer account with `sudo` access
- Python 3 for result processing
- NumPy and Matplotlib for plotting

Set the GAPBS, graph, and `CHMU_PERF_BIN` paths in:

```text
AE4/sw/config/benchmark_paths.env
```

Run setup and benchmarks as the reviewer account. The scripts use `sudo` for privileged operations when required.

## 1. Program the FPGA

Run the following commands on the FPGA programming server:

```bash
cd MICRO-2026-ARC/AE4
unzip -o program_script/chmu_ae_merge_SPL1.zip -d program_script
bash program_script/update_cdf_paths.sh
bash program_script/program_spr1.sh chmu_ae_merge_SPL1.cdf
```

Ask the authorized system operator to power-cycle the target host. BMC credentials and the power-cycle command are supplied separately.

After the target host boots, reconnect and verify the kernel and NUMA nodes:

```bash
uname -r
numactl -H
```

## 2. Configure the AE host

```bash
cd MICRO-2026-ARC/AE4
bash set_default/setup_default.sh all
```

The setup detects the target platform, loads the bundled kernel modules, builds the threshold managers, and applies the experiment settings.

## 3. Run the three Figure 11 workloads

This command runs `bc_tw`, `bfs_tw`, and `pr_tw` at threshold 16 without plotting:

```bash
bash sw/fig11/run_all_primary_th16.sh
```

The runner waits 30 seconds between new benchmark invocations.

If the command is interrupted, keep completed runs and continue with:

```bash
bash sw/fig11/run_all_primary_th16.sh --resume
```

## 4. Plot Figure 11

Check the plotting environment:

```bash
env PYTHONNOUSERSITE=1 \
  PYTHONPATH=/usr/lib/python3/dist-packages \
  python3 -c 'import numpy, matplotlib; print(numpy.__version__, matplotlib.__version__)'
```

Generate the combined figure from the completed logs:

```bash
env PYTHONNOUSERSITE=1 \
  PYTHONPATH=/usr/lib/python3/dist-packages \
  bash sw/fig11/plot_fig11_primary_combined.sh --threshold 16
```

## Expected result

```text
results/figure11/th16/figure11_primary_combined_normalized_performance.png
results/figure11/th16/figure11_primary_combined_normalized_performance.pdf
```

Normalized performance is `CXL-only geometric-mean time / method geometric-mean time`. Values above `1.0` are faster than CXL-only. Adaptive reports the faster complete result from the two initial epoch orders for each workload.

## More information

- [Detailed Figure 11 procedure](FIGURE11_REPRODUCTION.md)
- [Optional retraining and LOBO generation](sw/ml/README.md)
- [Bundled module source provenance](sw/prebuilt_module_source/README.md)
- [Third-party notices](THIRD_PARTY_NOTICES.md)
