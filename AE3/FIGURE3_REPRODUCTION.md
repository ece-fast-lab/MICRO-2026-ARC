# Figure 3 Reproduction and Optional Studies

Start after programming the SPL1 image, power-cycling the AE host, and running `set_default/setup_default.sh all` from the reviewer account.

## Figure 3 cases

| Order | Label | Mode | Threshold | Epoch A/B | Policy |
|---:|---|---|---:|---:|---|
| 1 | Baseline | `baseline` | 16 | `400000/400000` | CXL-node `membind`; demotion off |
| 2 | ANB | `anb` | 16 | `400000/400000` | Linux Auto NUMA Balancing |
| 3 | DAMON | `damon` | 16 | `400000/400000` | DAMON hot/cold migration |
| 4–7 | Cache-16/32/64/96 | `mig` | 16/32/64/96 | `400000/400000` | CHMU-Cache |
| 8–11 | CMS-16/32/64/96 | `mig` | 16/32/64/96 | `400001/400001` | CHMU-CMS |

The primary workload is GAPBS PageRank with the Twitter graph (`pr_tw`). The workload uses CPUs 0–7, and the manager uses CPU 20. The manager polling interval is 1 ms.

## Run all cases

Run the complete sweep without plotting:

```bash
bash sw/fig3/run_fig3_all_yes.sh
```

The wrapper runs all 11 cases and waits 30 seconds between newly executed cases.

Reuse valid cases after an interruption:

```bash
bash sw/fig3/run_fig3_all_yes.sh --resume
```

The result CSV is created after all 11 cases pass validation.

## Run individual cases

Valid case names are `baseline`, `anb`, `damon`, `cache16`, `cache32`, `cache64`, `cache96`, `cms16`, `cms32`, `cms64`, and `cms96`.

```bash
bash sw/fig3/run_fig3_case.sh pr_tw cache32
```

After running cases separately, validate the complete set and create the CSV:

```bash
bash sw/fig3/run_fig3_gapbs.sh pr_tw --case all --resume --skip-plot
```

## Resume or replace results

| Goal | Command |
|---|---|
| Keep valid cases and run missing cases | `bash sw/fig3/run_fig3_all_yes.sh --resume` |
| Replace every selected result | `bash sw/fig3/run_fig3_gapbs.sh pr_tw --case all all yes --skip-plot` |

Replacing a result moves the previous output to the next `.bak` path.

## Runtime metrics

### GAPBS

The parser requires exactly 10 complete `Trial Time:` records. It computes the geometric mean of records 6–10. The GAPBS `Average Time` field is not used.

### SPEC CPU2017

The parser requires a standalone `Run Complete` record. It uses the single `; N total seconds elapsed` record. Eight SPECrate copies form one run and are not treated as repeated trials.

### Normalization

```text
normalized_performance = baseline_seconds / method_seconds
normalized_runtime     = method_seconds / baseline_seconds
```

The plot uses normalized performance, so values above `1.0` are better.

## Outputs

```text
results/figure3/gapbs/pr_twitter/
  figure3_manifest.csv
  figure3_results.csv
  figure3_normalized_performance.png
  figure3_normalized_performance.pdf
```

Use the plotting command in [AE3 README](README.md#5-plot-existing-data) after data collection.

## Other workloads

GAPBS selectors are `bc_tw`, `bfs_tw`, `cc_tw`, `pr_tw`, `bc_web`, `bfs_web`, `cc_web`, and `pr_web`.

For example, run `bash sw/fig3/run_fig3_gapbs.sh bc_tw --skip-plot`.

Optional SPEC IDs are 502 (`gcc_r`), 505 (`mcf_r`), 507 (`cactuBSSN_r`), 527 (`cam4_r`), and 554 (`roms_r`). For example, run `bash sw/fig3/run_fig3_spec.sh 502 --skip-plot`.

## Optional Figure 6 epoch sweep

Figure 6 uses SPL1, threshold 64, and a 1 ms manager polling interval.

| Epoch | Cache | CMS |
|---:|---:|---:|
| 1 ms | `400000` | `400001` |
| 10 ms | `4000000` | `4000001` |
| 100 ms | `40000000` | `40000001` |
| 1000 ms | `400000000` | `400000001` |

Run `bash sw/fig6/run_fig6_epoch_gapbs.sh pr twitter` for GAPBS. Run `bash sw/fig6/run_fig6_epoch_spec.sh 502 --resume` for SPEC.

Use `--method cache|cms|both` and `--epoch 1|10|100|1000|all` to select points.

## Optional sampling-ratio study

Program the matching image, power-cycle the AE host, and rerun setup before each sampling run.

| Image | POF | Sampling | Default GAPBS threshold |
|---|---|---:|---:|
| SPL1 | `chmu_ae_merge_SPL1.pof` | 1/1 accesses | 64 |
| SPL2 | `chmu_ae_merge_SPL2.pof` | 1/2 accesses | 32 |
| SPL4 | `chmu_ae_merge_SPL4.pof` | 1/4 accesses | 16 |

Run `bash sw/optional/run_sampling_gapbs.sh pr twitter --sampling spl2` for GAPBS. Run `bash sw/optional/run_sampling_spec.sh 502 --sampling spl4 --threshold 16 --method both` for SPEC.

SPEC sampling requires an explicit threshold of 16, 32, 64, or 96.

## Troubleshooting

- Check `sw/config/benchmark_paths.env` if GAPBS, SPEC, or DAMON cannot be found.
- The Figure 3 driver retries lock contention for up to 300 seconds.
- Run with `--resume` if lock retry expires or a sweep is interrupted.
- Use the plotting environment in [AE3 README](README.md#5-plot-existing-data) if Matplotlib import fails.
