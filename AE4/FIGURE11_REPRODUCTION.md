# Figure 11 reproduction on SPR1

This is the reviewer path after the SPL1 POF has been programmed and SPR1 has
been power-cycled. The main path uses the supplied pretrained configuration;
the long trial-generation and Random Forest steps are intentionally skipped.

## 1. Set up SPR1 after reboot

Use the normal reviewer account. Do not enter `sudo -i` or run an entire setup
or benchmark command through `sudo`; the scripts elevate only the privileged
host controls and migration-manager operations.

```bash
cd MICRO_2026_ARC/AE4
bash set_default/setup_default.sh all
```

This detects the BAR/BDF and NUMA layout, validates and loads the bundled
kernel modules, builds the four threshold managers, and applies the
fixed-frequency and CHMU defaults. It does not program a POF or reboot the
server.

Confirm the absolute GAPBS and graph paths in:

```text
sw/config/benchmark_paths.env
```

Python 3 is needed for result collection. NumPy and Matplotlib are needed only
for the later PNG/PDF step, and the supplied runtime `.cfg` files do not
require scikit-learn.

## 2. Collect Figure 11 data without plotting

The primary reviewer workloads are `bc_tw`, `bfs_tw`, and `pr_tw`. For one
workload, the recommended automatic command runs all four reported methods,
accepts all benchmark confirmations, collects the CSV data, and skips
plotting. The Adaptive method evaluates both epoch orders as described below:

```bash
bash sw/fig11/run_fig11_all_yes.sh bc_tw --threshold 16
# Other choices: bfs_tw, pr_tw
```

To collect all three primary workload panels sequentially at threshold 16:

```bash
bash sw/fig11/run_all_primary_th16.sh
```

`run_all_primary_th16.sh` is also automatic-yes/data-only. If it is interrupted,
reuse all valid completed invocations and run only missing ones with:

```bash
bash sw/fig11/run_all_primary_th16.sh --resume
```

The hardware runners wait 30 seconds between newly executed canonical
invocations. The three-workload wrapper applies the same interval at a
workload boundary when the final invocation of the preceding workload was
newly executed. Reused `--resume` points, processing-only `--skip-benchmark`
runs, and the final selected invocation do not add an unnecessary wait. Keep
this reviewer default; `FIG11_CASE_INTERVAL_SEC=<seconds>` overrides it and
`0` disables it for diagnostics.

If another ARC command temporarily owns the shared SPR1 lock, the orchestrator
preserves every completed canonical result and retries only the current unit,
at 10-second intervals for at most 300 seconds. This recovery is activated
only by the benchmark runner's private lock-contention marker; ordinary setup,
workload, cleanup, and output-validation failures are printed live and are
never retried. Override the bounds with
`FIG11_LOCK_RETRY_INTERVAL_SEC=<seconds>` and
`FIG11_LOCK_RETRY_TIMEOUT_SEC=<seconds>`; timeout `0` disables automatic lock
retry. After a timeout or interruption, rerun the same command with `--resume`.

Each method can instead be run as a separate case:

```bash
bash sw/fig11/run_fig11_case.sh bc_tw cxl      --threshold 16
bash sw/fig11/run_fig11_case.sh bc_tw cache    --threshold 16
bash sw/fig11/run_fig11_case.sh bc_tw cms      --threshold 16
bash sw/fig11/run_fig11_case.sh bc_tw adaptive --threshold 16
```

The wrapper interface is
`run_fig11_case.sh <workload> <method> [--threshold N] [options]`. Normal method
names are `cxl`, `cache`, `cms`, and `adaptive`; `adaptive` runs both directions.
For diagnosis, the wrapper also accepts `adaptive_400000_400001` or
`adaptive_400001_400000` to run only that candidate, but a complete result
still requires both. The underlying runner additionally accepts `all` through
either `--method` or `--case`; use `run_fig11_all_yes.sh` for the automatic
all-method path. The case wrapper always skips plotting.

Each static bar consists of five independent invocations. Adaptive uses five
invocations in each of two epoch directions (ten Adaptive invocations total):

| Bar | Placement/policy | Epoch pair |
|---|---|---|
| CXL-only | Node 1 only, migration disabled; normalization baseline | N/A |
| CHMU-Cache | CXL to local migration, static Cache policy | `400000/400000` |
| CHMU-CMS | CXL to local migration, static CMS policy | `400001/400001` |
| Adaptive candidate 1 | PMU-driven Cache/CMS selection, starting from Cache | `400000/400001` |
| Adaptive candidate 2 | PMU-driven Cache/CMS selection, starting from CMS | `400001/400000` |

Adaptive does not switch unconditionally on every interval. It begins with the
first epoch in the pair and uses the online predictor plus the supplied
scale/hysteresis configuration to decide whether to switch. The two directions
therefore differ only in their initial Cache/CMS order; both use the same
frozen workload cfg. The runner rejects either direction unless the manager
log proves that the exact cfg was loaded and that the requested epoch pair and
ML policy were active.

At command start, the runner copies the selected cfg to a content-addressed,
read-only snapshot under the result directory. Consequently, replacing a
pretrained cfg cannot make `--resume` or `--skip-benchmark` mix Adaptive runs
from two cfg versions; old Adaptive repetitions fail validation and must be
rerun.

Each GAPBS invocation contains ten `Trial Time` values. The collector requires
all ten and selects positions 6--10. This produces 25 values for each static
method and 25 values for each Adaptive direction. It computes the geometric
mean of each direction independently and selects the direction with the lower
geometric-mean execution time (equivalently, the higher normalized
performance) for the single reported `Adaptive` bar. The raw selected-sample
CSV retains both directions for auditability; the summary CSV records the
winning direction and both candidate geometric means. The plotted normalized
performance is:

```text
CXL-only geometric-mean time / method geometric-mean time
```

Therefore, `1.0` is CXL-only and values above `1.0` are better.

### Rerun versus resume

`all yes` means unconditionally accept rerunning every selected case. If a
canonical run directory already exists, the common runner moves it to the next
numbered `.bak` path before replacement. Use `--resume`, not `all yes`, when an
interrupted command already has valid runs:

```bash
bash sw/fig11/run_fig11_th16.sh bc_tw --case all --resume --skip-plot
```

The equivalent explicit automatic fresh/rerun command is:

```bash
bash sw/fig11/run_fig11_th16.sh bc_tw --case all all yes --skip-plot
```

## 3. Plot completed data later

First verify that SPR1 uses the compatible Ubuntu system packages rather than
a conflicting NumPy/Matplotlib below `/usr/local` or the user site. Then call
the processing-only plot wrapper:

```bash
env PYTHONNOUSERSITE=1 \
  PYTHONPATH=/usr/lib/python3/dist-packages \
  python3 -c 'import numpy, matplotlib; print(numpy.__version__, matplotlib.__version__)'

env PYTHONNOUSERSITE=1 \
  PYTHONPATH=/usr/lib/python3/dist-packages \
  bash sw/fig11/plot_fig11.sh bc_tw --threshold 16
```

`plot_fig11.sh <workload> [--threshold N] [options]` validates and parses the
existing canonical logs with `--skip-benchmark`; it never starts hardware or
moves/reruns benchmark output.

After all three primary workloads have completed, generate the requested
single grouped figure containing `bc_tw`, `bfs_tw`, `pr_tw`, and `GeoMean`:

```bash
env PYTHONNOUSERSITE=1 \
  PYTHONPATH=/usr/lib/python3/dist-packages \
  bash sw/fig11/plot_fig11_primary_combined.sh --threshold 16
```

`plot_fig11_primary_combined.sh` is also processing-only. Before plotting, it
strictly validates all canonical runs for the three workloads and regenerates
their selected-sample and summary CSV files. It does not run setup, access the
FPGA, or start GAPBS. Each workload group contains the four CXL-only,
CHMU-Cache, CHMU-CMS, and Adaptive bars. For every method, the `GeoMean` group
is the geometric mean of that method's three normalized-performance values:

```text
(bc_tw normalized performance * bfs_tw normalized performance
 * pr_tw normalized performance)^(1/3)
```

The Adaptive direction is selected independently for each workload before
this cross-workload geometric mean is calculated.

If the system-package import fails, use a virtual environment only during the
plot step:

```bash
sudo apt install -y python3-venv
python3 -m venv "$HOME/.venvs/micro-2026-arc-plot"
source "$HOME/.venvs/micro-2026-arc-plot/bin/activate"
python3 -m pip install --upgrade pip
python3 -m pip install -r sw/fig11/requirements.txt
python3 -c 'import numpy, matplotlib; print(numpy.__version__, matplotlib.__version__)'
bash sw/fig11/plot_fig11_primary_combined.sh --threshold 16
deactivate
```

Outputs are written below:

```text
results/figure11/th16/<workload>/
```

They include the frozen cfg snapshot, a manifest, 25 selected samples per
static method plus 25 per Adaptive direction, geometric means, the selected
Adaptive direction, normalized performance, metadata with the cfg SHA-256,
and PNG/PDF plots.

The combined outputs are:

```text
results/figure11/th16/figure11_primary_combined_normalized_performance.png
results/figure11/th16/figure11_primary_combined_normalized_performance.pdf
```

## Optional workloads and thresholds

`cc_tw` and `pr_web` are optional:

```bash
bash sw/fig11/run_fig11_th16.sh cc_tw --skip-plot
bash sw/fig11/run_fig11_th16.sh pr_web --skip-plot
```

Threshold-specific wrappers are provided for 16, 32, 64, and 96:

```bash
bash sw/fig11/run_fig11_th32.sh bc_tw --skip-plot
bash sw/fig11/run_fig11_th64.sh bc_tw --skip-plot
bash sw/fig11/run_fig11_th96.sh bc_tw --skip-plot
```

## Optional SPEC extension (not the reviewer Figure 11 path)

The package also accepts one of `gcc`, `mcf`, `cactuB`, `cam4`, or `roms` and
uses its suite-isolated SPEC cfg:

```bash
bash sw/run_figure11_benchmark.sh spec gcc --threshold 16 --skip-plot
```

This optional path performs five complete SPEC invocations for each static
method and five per Adaptive direction. It uses the final anchored
`total seconds elapsed` value from every invocation, computes the two
five-sample Adaptive geometric means independently, and reports the faster
direction as one Adaptive bar. It intentionally does not apply GAPBS's
25-value Trial Time rule. Its outputs are under
`results/figure11_optional_spec/th16/<SPEC-ID>/`.

The optional SPEC runner uses the same 30-second newly-executed-unit interval,
bounded runner-marked lock retry, and `--resume` preservation rules as the
GAPBS reviewer runner.

Plot that optional result later with:

```bash
env PYTHONNOUSERSITE=1 \
  PYTHONPATH=/usr/lib/python3/dist-packages \
  bash sw/run_figure11_benchmark.sh spec gcc \
    --threshold 16 --skip-benchmark --yes
```

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
