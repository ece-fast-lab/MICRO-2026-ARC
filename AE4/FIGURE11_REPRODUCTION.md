# Figure 11 reproduction on the AE host

This procedure starts after the SPL1 image is programmed, the target host is rebooted, and `set_default/setup_default.sh all` completes. The main result uses the supplied pretrained configuration.

## Reported methods

| Method | Placement and policy | Epoch pair |
|---|---|---|
| CXL-only | Node 1 only; migration disabled | N/A |
| CHMU-Cache | CXL-to-local migration with Cache | `400000/400000` |
| CHMU-CMS | CXL-to-local migration with CMS | `400001/400001` |
| Adaptive candidate 1 | Dynamic Cache/CMS; starts from Cache | `400000/400001` |
| Adaptive candidate 2 | Dynamic Cache/CMS; starts from CMS | `400001/400000` |

Adaptive evaluates both initial epoch orders with the same workload cfg. The faster complete direction becomes the reported Adaptive bar.

## Run the primary workloads

Run all four reported bars for one workload:

```bash
bash sw/fig11/run_fig11_all_yes.sh bc_tw --threshold 16
# Other choices: bfs_tw, pr_tw
```

Run all three primary workloads:

```bash
bash sw/fig11/run_all_primary_th16.sh
```

The scripts collect data and CSV files without importing Matplotlib. New benchmark invocations are separated by 30 seconds.

## Run one method at a time

Use these commands for a staged run or to repeat one method:

```bash
bash sw/fig11/run_fig11_case.sh bc_tw cxl      --threshold 16
bash sw/fig11/run_fig11_case.sh bc_tw cache    --threshold 16
bash sw/fig11/run_fig11_case.sh bc_tw cms      --threshold 16
bash sw/fig11/run_fig11_case.sh bc_tw adaptive --threshold 16
```

The `adaptive` case runs both `400000/400001` and `400001/400000`. Run `bash sw/fig11/run_fig11_case.sh --help` for diagnostic selectors and other options.

## Sampling and normalization

Each static method uses five independent GAPBS invocations. Each Adaptive direction also uses five independent invocations. Every invocation must contain exactly ten `Trial Time` values. The collector keeps Trial Time positions 6–10 from each invocation. This gives 25 samples for each static method and 25 samples for each Adaptive direction.

The collector computes a geometric-mean execution time for each Adaptive direction. It reports the direction with the lower geometric mean.

Normalized performance is:

```text
CXL-only geometric-mean time / method geometric-mean time
```

CXL-only is `1.0`, and values above `1.0` are better.

## Resume or replace existing runs

Use `--resume` after an interruption:

```bash
bash sw/fig11/run_all_primary_th16.sh --resume
```

The runner reuses completed valid invocations and runs missing ones.

Without `--resume`, automatic confirmation replaces selected existing output after moving it to the next `.bakN` path:

```bash
bash sw/fig11/run_fig11_th16.sh bc_tw --case all all yes --skip-plot
```

Use `--resume` when preserving completed data is intended.

## Plot existing results

Plot `bc_tw`, `bfs_tw`, `pr_tw`, and their cross-workload geometric mean:

```bash
env PYTHONNOUSERSITE=1 \
  PYTHONPATH=/usr/lib/python3/dist-packages \
  bash sw/fig11/plot_fig11_primary_combined.sh --threshold 16
```

The `GeoMean` group is computed separately for each method from its three normalized-performance values. Adaptive direction selection occurs before the cross-workload geometric mean is calculated.

Per-workload results are stored below:

```text
results/figure11/th16/<workload>/
```

The combined outputs are:

```text
results/figure11/th16/figure11_primary_combined_normalized_performance.png
results/figure11/th16/figure11_primary_combined_normalized_performance.pdf
```

## Optional paths

`cc_tw` and `pr_web` use the same runner:

```bash
bash sw/fig11/run_fig11_th16.sh cc_tw --skip-plot
bash sw/fig11/run_fig11_th16.sh pr_web --skip-plot
```

Threshold wrappers are available for 16, 32, 64, and 96:

```bash
bash sw/fig11/run_fig11_th32.sh bc_tw --skip-plot
bash sw/fig11/run_fig11_th64.sh bc_tw --skip-plot
bash sw/fig11/run_fig11_th96.sh bc_tw --skip-plot
```

The optional SPEC path accepts `gcc`, `mcf`, `cactuB`, `cam4`, or `roms`:

```bash
bash sw/run_figure11_benchmark.sh spec gcc --threshold 16 --skip-plot
```

SPEC results are stored below `results/figure11_optional_spec/th16/<SPEC-ID>/`. Local-only is omitted because it requires a different boot-time memory map with more capacity on NUMA Node 0. Optional configuration training is documented in [`sw/ml/README.md`](sw/ml/README.md).

## Troubleshooting

- If a run is interrupted or the shared ARC lock times out, rerun the same command with `--resume`.
- If a benchmark path is missing, update `sw/config/benchmark_paths.env`.
- If NumPy or Matplotlib cannot be imported, install `sw/fig11/requirements.txt` in a plotting-only virtual environment.
