# Figure 11 reproduction on SPR1

This is the reviewer path after the SPL1 POF has been programmed and SPR1 has
been power-cycled. The main path uses the supplied pretrained configuration;
the long trial-generation and Random Forest steps are intentionally skipped.

## 1. Set up SPR1 after reboot

```bash
cd MICRO_2026_ARC/AE4
bash set_default/setup_default.sh all
```

This detects the BAR/BDF and NUMA layout, builds the four threshold managers,
loads the modules, and applies the fixed-frequency and CHMU defaults. It does
not program a POF or reboot the server.

Confirm the absolute GAPBS and graph paths in:

```text
sw/config/benchmark_paths.env
```

Figure 11 needs Python 3 and Matplotlib for result processing. The supplied
runtime `.cfg` files do not require scikit-learn.

## 2. Run one Figure 11 workload

The primary reviewer workloads are `bc_tw`, `bfs_tw`, and `pr_tw`. Select one:

```bash
bash sw/fig11/run_fig11_th16.sh bc_tw
bash sw/fig11/run_fig11_th16.sh bfs_tw
bash sw/fig11/run_fig11_th16.sh pr_tw
```

The script asks for confirmation before the experiment and before each
benchmark invocation. To accept every prompt:

```bash
bash sw/fig11/run_fig11_th16.sh bc_tw all yes
```

To reproduce all three primary workload panels sequentially:

```bash
for b in bc_tw bfs_tw pr_tw; do
  bash sw/fig11/run_fig11_th16.sh "$b" all yes
done
```

Each command runs five independent invocations of each method:

| Bar | Placement/policy | Epoch pair |
|---|---|---|
| CXL-only | Node 1 only, migration disabled; normalization baseline | N/A |
| CHMU-Cache | CXL to local migration, static Cache policy | `400000/400000` |
| CHMU-CMS | CXL to local migration, static CMS policy | `400001/400001` |
| Adaptive | PMU-driven Cache/CMS selection using the supplied workload cfg | `400000/400001` |

Adaptive does not switch unconditionally on every interval. It begins with the
Cache epoch and uses the online predictor plus the supplied scale/hysteresis
configuration to decide whether to switch. The runner rejects a run unless the
manager log proves that the exact cfg was loaded and the ML policy was active.
At command start, it copies the selected cfg to a content-addressed, read-only
snapshot under the result directory. Consequently, replacing a pretrained cfg
cannot make `--resume` or `--skip-benchmark` mix adaptive runs from two cfg
versions; old adaptive repetitions fail validation and must be rerun.

Each GAPBS invocation contains ten `Trial Time` values. The collector requires
all ten, selects positions 6--10 from each of the five invocations, combines
the resulting 25 values per method, and computes a geometric mean. The plotted
normalized performance is:

```text
CXL-only geometric-mean time / method geometric-mean time
```

Therefore, `1.0` is CXL-only and values above `1.0` are better.

## 3. Resume or process existing output

If an interrupted command already has valid runs, continue without repeating
them:

```bash
bash sw/fig11/run_fig11_th16.sh bc_tw --resume
```

If a canonical run directory exists and must be rerun, the script asks first;
the common runner moves the old directory to `.bakN`. To validate and plot
already completed canonical logs without touching hardware:

```bash
bash sw/fig11/run_fig11_th16.sh bc_tw --skip-benchmark
```

Outputs are written below:

```text
results/figure11/th16/<workload>/
```

They include the frozen cfg snapshot, a manifest, all selected 25 samples per
method, geometric means, normalized performance, metadata with the cfg
SHA-256, and PNG/PDF plots.

## Optional workloads and thresholds

`cc_tw` and `pr_web` are optional:

```bash
bash sw/fig11/run_fig11_th16.sh cc_tw
bash sw/fig11/run_fig11_th16.sh pr_web
```

Threshold-specific wrappers are provided for 16, 32, 64, and 96:

```bash
bash sw/fig11/run_fig11_th32.sh bc_tw
bash sw/fig11/run_fig11_th64.sh bc_tw
bash sw/fig11/run_fig11_th96.sh bc_tw
```

## Optional SPEC extension (not the reviewer Figure 11 path)

The package also accepts one of `gcc`, `mcf`, `cactuB`, `cam4`, or `roms` and
uses its suite-isolated SPEC cfg:

```bash
bash sw/run_figure11_benchmark.sh spec gcc --threshold 16
```

This optional path performs five complete SPEC invocations per method and uses
the final anchored `total seconds elapsed` value from each, so its bar is a
five-sample geometric mean. It intentionally does not apply GAPBS's 25-value
Trial Time rule. Its outputs are under
`results/figure11_optional_spec/th16/<SPEC-ID>/`.

## Why Local-only is omitted

The reviewer figure intentionally omits Local-only. A valid Local-only run
requires changing the reboot-time memory map/layout so that NUMA Node 0 has
enough capacity for the graph, then rebooting and rerunning setup. It is
expected to be the fastest placement and is not needed for the four-bar
adaptive-versus-static comparison. An expert who has prepared that different
boot configuration can use `--include-local` together with the explicit guard
`CONFIRM_LOCAL_MEMMAP=YES`; those results are not the default reviewer path.

The collector, plotter, and processing-only shell integration tests can be run
without SPR1 hardware access:

```bash
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s sw/fig11/tests -v
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s sw/fig11_spec/tests -v
```

## Optional training and LOBO regeneration

Do not run this section for the normal AE path; it is much longer. The two
entry points below target 20 successful complete executions for one workload:

```bash
bash sw/ml/run_training_gapbs.sh bc_tw --threshold 16
bash sw/ml/run_training_spec.sh gcc --threshold 16
```

Allowed GAPBS inputs are `bc_tw`, `bfs_tw`, `cc_tw`, `pr_tw`, and `pr_web`.
Allowed SPEC inputs are `gcc`, `mcf`, `cactuB`, `cam4`, and `roms`. The same
scripts accept thresholds 32, 64, and 96. See `sw/ml/README.md` for the full
suite-isolated LOBO and replacement procedure.
