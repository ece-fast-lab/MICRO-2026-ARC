# AE4 – Adaptive Cache/CMS Performance (Figure 11)

AE4 compares CXL-only, static CHMU-Cache, static CHMU-CMS, and Adaptive for
GAPBS `bc_tw`, `bfs_tw`, and `pr_tw`, then draws the three workloads and their
geometric mean in one figure. This front section is the complete reviewer
path. Training, optional SPEC runs, and implementation details are preserved
in the [Appendix](#appendix-detailed-reference).

## Artifact at a glance

| Item | Reviewer path |
|---|---|
| Target | Figure 11 with `bc_tw`, `bfs_tw`, and `pr_tw` |
| FPGA image | `chmu_ae_merge_SPL1` |
| Methods | CXL-only, CHMU-Cache, CHMU-CMS, Adaptive |
| Supplied model | Pretrained suite-isolated LOBO configuration |
| Main output | Three workloads plus `GeoMean` in one PNG/PDF |

## Quick start

Run commands from the normal reviewer account. Do not use `sudo -i` and do
not put `sudo` in front of an entire setup or benchmark command. NumPy and
Matplotlib are needed only for the final plot.

### 1. Program the SPL1 FPGA image

On the FPGA programming server:

```bash
cd MICRO-2026-ARC/AE4
unzip -o program_script/chmu_ae_merge_SPL1.zip -d program_script
bash program_script/update_cdf_paths.sh
bash program_script/program_spr1.sh chmu_ae_merge_SPL1.cdf
```

Use the power-cycle command supplied separately by the authorized system
operator. BMC credentials are intentionally not included in this artifact.
Wait for SPR1 to boot, reconnect, and verify the custom kernel and NUMA nodes:

```bash
uname -r
numactl -H
```

Expected kernel: `6.11.0-mig-offload+`. If SPR1 has not already been
provisioned, follow the separate [custom-kernel guide](../kernel/README.md)
before starting the reviewer path.

### 2. Check the external benchmark paths

On SPR1, verify the GAPBS binaries, Twitter graph, and `CHMU_PERF_BIN` in:

```text
AE4/sw/config/benchmark_paths.env
```

### 3. Configure SPR1

```bash
cd MICRO-2026-ARC/AE4
bash set_default/setup_default.sh all
```

### 4. Collect all three primary workloads

The wrapper runs `bc_tw`, `bfs_tw`, and `pr_tw` sequentially, accepts all
prompts, collects CSV results, and skips plotting:

```bash
cd MICRO-2026-ARC/AE4
bash sw/fig11/run_all_primary_th16.sh
```

After an interruption, preserve complete canonical runs and continue:

```bash
bash sw/fig11/run_all_primary_th16.sh --resume
```

### 5. Plot the combined Figure 11

This processing-only command validates existing runs and does not access the
FPGA or start GAPBS:

```bash
cd MICRO-2026-ARC/AE4
env PYTHONNOUSERSITE=1 \
  PYTHONPATH=/usr/lib/python3/dist-packages \
  bash sw/fig11/plot_fig11_primary_combined.sh --threshold 16
```

## Expected output

```text
results/figure11/th16/figure11_primary_combined_normalized_performance.png
results/figure11/th16/figure11_primary_combined_normalized_performance.pdf
```

The plot reports `CXL-only time / method time`; values above `1.0` are better.
Adaptive uses five repetitions in each epoch direction and reports the faster
complete direction for each workload. See
[`FIGURE11_REPRODUCTION.md`](FIGURE11_REPRODUCTION.md) for the detailed flow
and [`sw/ml/README.md`](sw/ml/README.md) for optional retraining.

## Optional current-system retraining

This is not required for Figure 11 reproduction. It runs five GAPBS workloads
20 times each (100 complete invocations), then proposes a new GAPBS-only LOBO
configuration profile without modifying the shipped pretrained files:

```bash
cd MICRO-2026-ARC/AE4
python3 -m venv "$HOME/.venvs/micro-2026-arc-ml"
source "$HOME/.venvs/micro-2026-arc-ml/bin/activate"
python3 -m pip install -r sw/ml/requirements.txt
bash sw/ml/run_training_gapbs_all.sh \
  --threshold 16 --profile current-system all yes
```

After an interruption, rerun the same command with `--resume`. Both the Twitter
and Web graphs and a working custom `CHMU_PERF_BIN` are required. Full setup,
status, output, LOBO, and candidate-validation commands are in
[`sw/ml/README.md`](sw/ml/README.md).

# Appendix: Detailed reference

## Detailed reviewer workflow

After the SPL1 POF has been programmed and SPR1 has been power-cycled, run the
hardware setup and long data collection from the normal reviewer account. Do
not use `sudo -i` or put `sudo` in front of an entire benchmark command.

### 1. Set up SPR1

```bash
cd MICRO_2026_ARC/AE4
bash set_default/setup_default.sh all
```

### 2. Collect benchmark data without plotting

For one primary workload, the following convenience wrapper accepts all
prompts, runs all four reported methods at threshold 16, validates/collects
their data, and skips PNG/PDF generation. Adaptive evaluates five repetitions
of both `400000/400001` and `400001/400000` and reports the better direction:

```bash
bash sw/fig11/run_fig11_all_yes.sh bc_tw --threshold 16
# Other primary choices: bfs_tw, pr_tw
```

To collect all three primary workloads sequentially with automatic yes and
plotting disabled:

```bash
bash sw/fig11/run_all_primary_th16.sh
```

Newly executed canonical invocations are separated by 30 seconds, including
the boundary between primary workloads when needed. Valid points reused by
`--resume`, processing-only `--skip-benchmark` calls, and the final selected
unit do not incur an extra wait. Keep the default for reviewer runs; set
`FIG11_CASE_INTERVAL_SEC=<seconds>` to override it (`0` disables it for
diagnostics).

If the shared ARC host lock is temporarily busy, only the current canonical
unit is retried, every 10 seconds for at most 300 seconds. The retry requires
the benchmark runner's private lock-contention marker, so ordinary benchmark,
setup, cleanup, and validation errors remain visible on stderr and are not
retried. Configure the bounds with `FIG11_LOCK_RETRY_INTERVAL_SEC` and
`FIG11_LOCK_RETRY_TIMEOUT_SEC`; timeout `0` disables automatic retry. On a
timeout or interruption, repeat the command with `--resume` to preserve all
valid completed results.

The four methods can instead be run separately. This is useful for a staged
review or for rerunning only one failed case:

```bash
bash sw/fig11/run_fig11_case.sh bc_tw cxl      --threshold 16
bash sw/fig11/run_fig11_case.sh bc_tw cache    --threshold 16
bash sw/fig11/run_fig11_case.sh bc_tw cms      --threshold 16
bash sw/fig11/run_fig11_case.sh bc_tw adaptive --threshold 16
```

`run_fig11_case.sh <workload> <method> [--threshold N] [options]` accepts
`cxl`, `cache`, `cms`, or `adaptive`; `adaptive` runs both epoch directions.
Diagnostic selectors `adaptive_400000_400001` and
`adaptive_400001_400000` run only one candidate, but cannot by themselves
produce the final Adaptive bar. The main runner additionally accepts `all`
through either `--method` or `--case`; the automatic all-method wrapper is
`run_fig11_all_yes.sh`. The case wrapper always skips the plot step.

`all yes` unconditionally accepts rerunning selected canonical cases. Existing
output is moved to the next numbered `.bak` path before replacement. To
continue after an interruption while preserving valid completed invocations,
use `--resume` instead:

```bash
bash sw/fig11/run_fig11_th16.sh bc_tw --case all --resume --skip-plot
bash sw/fig11/run_all_primary_th16.sh --resume
```

### 3. Plot later without running hardware

On SPR1, select the compatible Ubuntu NumPy/Matplotlib packages explicitly so
a package installed below `/usr/local` or the user site cannot take precedence:

```bash
env PYTHONNOUSERSITE=1 \
  PYTHONPATH=/usr/lib/python3/dist-packages \
  python3 -c 'import numpy, matplotlib; print(numpy.__version__, matplotlib.__version__)'

env PYTHONNOUSERSITE=1 \
  PYTHONPATH=/usr/lib/python3/dist-packages \
  bash sw/fig11/plot_fig11.sh bc_tw --threshold 16
```

`plot_fig11.sh <workload> [--threshold N] [options]` is processing-only. It
validates the existing canonical logs, computes the selected-sample and
summary CSVs, and creates PNG/PDF without changing hardware or rerunning a
benchmark.

After `bc_tw`, `bfs_tw`, and `pr_tw` have all completed, generate one grouped
figure with those three workloads and their cross-workload geometric mean:

```bash
env PYTHONNOUSERSITE=1 \
  PYTHONPATH=/usr/lib/python3/dist-packages \
  bash sw/fig11/plot_fig11_primary_combined.sh --threshold 16
```

The combined wrapper is processing-only. It first strictly validates the
existing canonical runs and regenerates all three summary CSVs, without
touching the FPGA or starting GAPBS. It then plots CXL-only, CHMU-Cache,
CHMU-CMS, and Adaptive for each workload plus a `GeoMean` group. Each
geometric-mean bar is computed from that method's three normalized-performance
values. Adaptive first selects the faster epoch direction independently for
each workload.

If the system-package import fails, use a plotting-only virtual environment:

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

Each complete workload contains five GAPBS invocations for CXL-only,
CHMU-Cache, and CHMU-CMS. Adaptive contains five invocations in each epoch
direction, `400000/400001` and `400001/400000`. From every invocation the
collector selects Trial Time 6--10, giving 25 samples per static method and 25
samples per Adaptive direction. It computes the two Adaptive geometric means
independently and uses the direction with the lower execution time for the
single reported Adaptive bar. Both direction results remain in the manifest
and selected-sample CSV for auditability.

The plotted geometric-mean normalized performance is:

```text
CXL-only geometric-mean time / method geometric-mean time
```

Values above `1.0` are better. Results are stored below
`results/figure11/th16/<workload>/` as raw-run manifests, selected-sample CSV,
summary CSV, metadata, PNG, and PDF.

The combined PNG/PDF are written as
`results/figure11/th16/figure11_primary_combined_normalized_performance.{png,pdf}`.

## What is included

| Component | Function | Configuration time |
|---|---|---|
| `set_default/setup_default.sh` | Preflight, platform detection, prebuilt-module validation, four manager builds, system defaults, module loading, and CHMU initialization | Setup |
| `sw/migration_manager` | Reads CHMU hot-page data and requests page migration | Build and run |
| `sw/kmod_pgmigrate` | Bundled `page_migrate.ko` plus source fallback for the custom-kernel migration interface | Setup; fallback build only |
| `sw/kmod_pac_ofw_buf` | Bundled `pac_ofw_buf.ko` plus source fallback for the DRAM overflow buffer | Setup; fallback build only |
| `sw/prebuilt_module_source` | Exact legacy source snapshot and hashes for the bundled modules | Provenance only |
| `sw/pcimem` and `sw/set_para` | Access BAR2; disable/reset/arm tracking; set threshold, epoch, address, and tracker CSRs | Setup and run |
| `sw/core_pqos` | Reproduces the SPR1 CPU offlining and LLC-way allocation | Benchmark run |
| `sw/build_option_th{16,32,64,96}` | Reviewer entry points for the four runtime thresholds | Benchmark run |
| `sw/benchmark` | Common GAPBS and SPEC runners | Benchmark run |
| `sw/fig11` | Five-repeat static and five-per-direction Adaptive runner, strict collector, and Figure 11 plotter | Figure 11 |
| `sw/fig11_spec` | Optional five-repeat static and five-per-direction Adaptive SPEC four-bar runner and collector | Optional extension |
| `sw/ml/pretrained` | Rank-1 GAPBS and SPEC cfgs for thresholds 16/32/64/96 | Adaptive run |
| `sw/ml` | Optional 20-trial optimizer and suite-isolated LOBO generator | Optional training |

The four manager binaries have the same source and compile options. The
directory name selects the reviewer-facing threshold, and each wrapper writes
that threshold to CSR `0xC8` at runtime. Separate build directories preserve
the original experiment interface without pretending that threshold is a
compile-time option.

## SPR1 prerequisites

Use the SPR1 custom `6.11.0-mig-offload+` kernel. This artifact includes the
two kernel modules built by the original SPR1 setup. Normal setup verifies
their names, SHA-256 hashes, and vermagic and therefore does not need a kernel
build tree. A matching build tree with the non-upstream
`linux/cxl_migrate.h` interface and `Module.symvers` is required only if the
bundled modules are absent or invalid and a source fallback build is needed.
The optional one-time source, build, install, and GRUB procedure is documented
in the repository's [custom-kernel guide](../kernel/README.md); it is not run
by `setup_default.sh all`.
The running kernel command line must contain these exact tokens:

```text
intel_iommu=on,sm_on iommu=pt no5lvl efi=nosoftreserve memmap=124G$0x180000000
```

The default hardware gate also requires hostname `spr1`, PCI ID `8086:0ddb`,
and the CHMU function to be PCI function `.1`. `ALLOW_NON_SPR1=1` and the
detection overrides are provided only for an intentional port, not for normal
artifact evaluation.

The setup preflight checks for CMake, GCC/G++, libnuma headers, PCI utilities,
numactl, msr-tools, PQoS, perf, cgroup v2, the bundled kernel modules, and CPU
frequency controls. Matching kernel headers are checked only for a fallback
module build. The reviewer account needs passwordless or initially
interactive `sudo` access for modules, MSRs, sysfs, cgroups, PCI configuration,
and MMIO; benchmark runners refresh the authenticated timestamp without
prompting during long runs.
Run the setup and workloads from the reviewer account rather than a `sudo -i`
shell. The scripts invoke sudo only for the controls that need it, and keep the
benchmark workload under the reviewer UID. Python 3 is required for result
collection; NumPy and Matplotlib are needed only when the plot is generated.
If an earlier benchmark left the intended isolation mask (`0-7,20` online),
setup reports the inactive CPUs' frequency controls as `SKIP`; it still
strictly validates and sets the active workload/manager CPUs to 2.0 GHz.
Setup changes host-wide CPU, NUMA, swap, PCI, and MMIO state, so use SPR1
exclusively. State-changing setup actions and benchmark entry points share an
exclusive lock and refuse to overlap with another ARC run; read-only
`check`/`status` may run without that lock.

## One-command setup

From the repository root of a fresh clone on SPR1:

```bash
cd AE4
bash set_default/setup_default.sh all
```

`all` performs these actions in order:

1. Checks the required SPR1 environment.
2. Detects the CHMU PCI function, BAR2 `resource2`, the memory-only CXL NUMA
   node, the DRAM buffer node, the CXL physical start address, and PFN range.
3. Builds `pcimem` and `build_option_th16`, `build_option_th32`,
   `build_option_th64`, and `build_option_th96`. It validates and reuses the
   bundled kernel modules, skipping both module builds.
4. Sets CPU frequency to 2.0 GHz, disables turbo, locks uncore ratio to
   `0x1919`, enables NUMA demotion and tiering mode, resets swap, loads the
   modules, and initializes the CHMU registers.
5. Prints status without starting a benchmark.

The host-specific detection result is written to the ignored file
`set_default/generated/platform.env`. It is consumed both by CMake and the
runtime BAR helpers; no source file is rewritten. Detection requires the CXL
node's online memory blocks to form one contiguous physical range, and derives
the PFN count from the exact block count and system memory-block size.

If auto-detection is ambiguous, specify the hardware explicitly:

```bash
PCIE_BDF=0000:40:00.1 CXL_NODE=1 BUFFER_NODE=0 \
  bash set_default/setup_default.sh all
```

For staged diagnosis, use `check`, `detect`, `build`, `apply`, and `status`
separately. `disable` stops CHMU tracking, unloads the two artifact modules,
and disables NUMA demotion.

If `apply` fails after module loading, it disables tracking, unloads the
artifact modules, and restores NUMA balancing/demotion. It cannot reliably
restore every CPU/MSR, swap, or `numad` change. After such a failure, inspect
the reported error and either rerun `all` from a known-good SPR1 state or
reboot SPR1 before collecting results. For a normal teardown, run:

```bash
bash set_default/setup_default.sh disable
```

System and CSR defaults can be overridden as environment variables before
invocation; their documented defaults are in
`set_default/config/defaults.env`. Set `RESET_SWAP=0` to omit the original
setup's swap reset.

## BAR and platform values

| Value | Where it is used |
|---|---|
| BAR2 `resource2` path | Compiled into each migration manager and used by `pcimem` at runtime |
| Full PCI BDF | Used at runtime by `setpci` to enable PCI memory space |
| CXL start, first PFN, PFN count | Passed to all four manager builds and to a fallback page-module build, if one is required |
| CXL NUMA node and DRAM buffer node | Select runner source/destination nodes, the manager migration target, and overflow-buffer allocation node |
| Threshold `16/32/64/96` | Written at runtime to CSR `0xC8` by the selected directory's wrapper |
| Epoch `400000/400001` | Written at runtime to CSR `0x40`; the LSB selects Cache or CMS mode |
| Host address offset `0x180000000` | Written to CSR `0x70`, matching the original benchmark-time setting |

Thus the BAR path is a build input, while the BDF, threshold, and epoch are
also required by the runtime setup path.

Every benchmark begins by disabling CHMU and clearing the PFN queue. Baseline,
ANB, and DAMON modes keep tracking disabled. Migration mode configures the BAR
values while disabled, waits until the privileged manager and (for dynamic
switching) its PMU collectors report ready, clears the queue again, and only
then enables the selected epoch and push rate. Cleanup disables tracking, so a
later run cannot consume stale PFNs from an earlier workload.

The runners also refuse to reuse a nonempty artifact cgroup. If an interrupted
older run left processes in `/sys/fs/cgroup/app`, clean up those processes (or
reboot SPR1) before retrying; the artifact will not kill unknown stale tasks.

## External benchmark paths

SPEC CPU2017, GAPBS binaries, and graph datasets are not distributed here.
Before running a benchmark, verify the absolute SPR1 paths in:

```text
sw/config/benchmark_paths.env
```

Set `SPEC_ROOT`, `SPEC_RUNCPU`, and the absolute `SPEC_CONFIG` path for SPEC.
Set `GAPBS_ROOT` and either the graph directory or the explicit
`GAPBS_WEB_GRAPH`/`GAPBS_TWITTER_GRAPH` paths for GAPBS. Optional DAMON runs
also require absolute `DAMO_BIN` and `DAMO_CONFIG` paths.

## Low-level GAPBS entry points

The commands in this section are diagnostic building blocks. Use
`sw/fig11/run_fig11_th*.sh` for reported Figure 11 results because that path
selects the correct pretrained cfg, checks that the manager actually loaded
it, freezes a SHA-256-addressed cfg snapshot in the result directory, performs
five repetitions per static method and per Adaptive direction, and applies the
25-sample metric independently before selecting the better Adaptive direction.

Each threshold directory contains the same five portable wrappers. Arguments
are mandatory: benchmark is `bc`, `bfs`, `cc`, or `pr`; database is `web` or
`twitter`.

Cache-CHMU-only migration, epoch LSB `0`:

```bash
./sw/build_option_th16/run_test_indv_gap_400000_400000 bc twitter
```

CMS-CHMU-only migration, epoch LSB `1`:

```bash
./sw/build_option_th16/run_test_indv_gap_400001_400001 bc twitter
```

Dynamic Cache/CMS switching requires an explicit workload cfg. For example:

```bash
CHMU_MODEL_PATH="$PWD/sw/ml/pretrained/th16/gap/bc_twitter.cfg" \
  ./sw/build_option_th16/run_test_indv_gap_400000_400001 bc twitter
```

That command is the retained low-level forward-direction diagnostic wrapper.
The reported Figure 11 orchestrator invokes the common runner directly for
both epoch orders, executes five of each direction with the same cfg, and
selects the lower 25-sample geometric-mean time for the single Adaptive bar.
Use `sw/fig11/run_fig11_case.sh ... adaptive`, rather than inventing a reverse
low-level wrapper name, to run both canonical candidates.

Dynamic switching (`400000 != 400001`) is accepted only after both core and IMC
`perf` collectors produce usable samples. Collector startup/runtime failure
fails the manager and the benchmark command instead of silently changing the
algorithm. `CHMU_ALLOW_PREDICTOR_FALLBACK=1` enables the old duplicate-policy
fallback for debugging only; results from that override are not the reported
dynamic configuration.

On SPR1, AE4 uses the real perf executable that produced the original adaptive
results:

```bash
/research/chihuns2/kernel/linux-6.5.5/tools/perf/perf --version
```

The path is set as `CHMU_PERF_BIN` in `sw/config/benchmark_paths.env` and may be
overridden with another tested absolute `tools/perf/perf` path. Do not select
`/usr/bin/perf`: on the custom `6.11.0-mig-offload+` kernel it is only an Ubuntu
dispatcher and exits because no matching distro linux-tools package exists.

The original convenience entry point is also retained for diagnosis; it runs
Cache-only, CMS-only, and dynamic switching sequentially. Supply a matching
absolute `CHMU_MODEL_PATH` before using its dynamic point:

```bash
./sw/build_option_th16/run_test_indv_gap bc twitter
```

Replace `th16` with `th32`, `th64`, or `th96` to select another threshold.
Outputs and logs are stored below that threshold's `output/` directory and are
ignored by Git.

The runner uses the current SPR1 CPU layout: CPUs 0-7 for the workload, CPU 20
for the manager, and every other CPU in 8-31 offline, with fixed LLC-way
allocation. `SKIP_CPU_ISOLATION=1` bypasses that step for debugging only and
does not reproduce the reported configuration.

`migration_manager` is the only long-running process started through `sudo`,
because it opens BAR2 and writes the root-only migration proc nodes. Before a
GAPBS/SPEC workload starts, it stops at a short gate while the runner uses root
only to attach that PID to `/sys/fs/cgroup/app`; the runner verifies membership
and resumes it. The workload UID remains the reviewer account throughout.

The runner waits for a root-created readiness record, verifies the actual
manager PID and executable, resets/arms CHMU, and then releases the manager's
explicit start gate. It uses `SIGINT` plus a bounded TERM/KILL fallback, and
the manager retains each collector process-group ID so it can stop `perf` and
its children even if the group leader exits first. PMU temporary files are
kept in a root-owned mode-0700 per-run directory below `/run`, then ownership
is dropped before the files are archived into the run output. Manager,
background-control, tracker-disable, and workload failures are recorded and
propagated rather than reported as successful runs.

## Optional SPEC CPU2017 entry point

SPEC is not part of the main Figure 11 reviewer path. Its dynamic Cache/CMS
wrapper accepts the numeric benchmark name and defaults to eight copies. Set
the supplied threshold/workload cfg explicitly:

```bash
CHMU_MODEL_PATH="$PWD/sw/ml/pretrained/th16/spec/502.cfg" \
  ./sw/build_option_th16/run_test_indv_spec_400000_400001 502
```

Override the copy count only when the experiment requires it:

```bash
CHMU_SPEC_COPIES=8 \
  ./sw/build_option_th32/run_test_indv_spec_400000_400001 505
```

The common runners additionally support `baseline`, `anb`, and `damon` modes.
They are exposed directly in `sw/benchmark/run_gapbs.sh` and
`sw/benchmark/run_spec.sh`; run either without arguments to see its exact
interface.

## Optional training and pretrained cfgs

Normal reviewers should use the supplied cfgs and skip training. The package
contains all 40 rank-1 files:

```text
4 thresholds x (5 GAPBS + 5 SPEC) workloads
```

They were generated by suite-separated LOBO: a held-out SPEC configuration is
derived only from the other SPEC workloads, and a held-out GAPBS configuration
only from the other GAPBS workloads. The supplied files are based on the
available accumulated lab histories, whose per-workload counts vary; they are
not claimed to be exactly 20 trials each.

For an optional current-system threshold-16 study, the all-five driver targets
20 successful complete invocations for each of `bc_tw`, `bfs_tw`, `cc_tw`,
`pr_tw`, and `pr_web`: 100 optimizer rows in total. It alternates the two epoch
orders, validates every completed run, and generates the GAPBS-only LOBO output
after all histories are complete:

```bash
bash sw/ml/run_training_gapbs_all.sh \
  --threshold 16 --profile current-system all yes
```

Resume without discarding completed rows or inspect progress with:

```bash
bash sw/ml/run_training_gapbs_all.sh \
  --threshold 16 --profile current-system --resume all yes
bash sw/ml/run_training_gapbs_all.sh \
  --threshold 16 --profile current-system --status
```

The optional offline tools need NumPy, Matplotlib, scikit-learn, and joblib.
Training uses each invocation's printed all-ten-trial arithmetic `Average Time`;
this is distinct from Figure 11's 25-value reporting metric. Generated rank-1
files are proposed candidates and remain below the named result profile. They
do not overwrite `sw/ml/pretrained`. Full prerequisites, result paths, LOBO
details, and isolated candidate-validation commands are in `sw/ml/README.md`.

## Optional selectable SPEC comparison

Figure 11 and the reviewer quick path remain GAPBS-only. For completeness, the
same four policies can also be run for one restricted SPEC workload with the
corresponding SPEC-only LOBO cfg:

```bash
bash sw/run_figure11_benchmark.sh spec gcc --threshold 16 --skip-plot
# Other choices: mcf, cactuB, cam4, roms
```

The same dispatcher accepts GAPBS, for example
`bash sw/run_figure11_benchmark.sh gapbs bc_tw --threshold 16`. The optional
SPEC path runs five complete invocations per static method and five for each
Adaptive epoch direction. It selects the final anchored
`total seconds elapsed` value from each invocation, computes each five-sample
geometric mean, selects the faster Adaptive direction for the single Adaptive
bar, and plots `CXL-only time / method time`. This metric is kept separate from
the reported GAPBS 25-value metric. Threshold-specific SPEC wrappers are under
`sw/fig11_spec/run_fig11_spec_th{16,32,64,96}.sh`.

Its multiple invocations use the same 30-second newly-executed-unit interval,
bounded lock-contention-only retry, and `--resume` behavior as the GAPBS path.

After the optional SPEC data completes, regenerate its CSV and plot without
running hardware by using the same plotting environment described above:

```bash
env PYTHONNOUSERSITE=1 \
  PYTHONPATH=/usr/lib/python3/dist-packages \
  bash sw/run_figure11_benchmark.sh spec gcc \
    --threshold 16 --skip-benchmark --yes
```

Local-only is deliberately absent from the reviewer figure. A valid run needs
a reboot-time memory-map/layout change that gives NUMA Node 0 enough capacity,
followed by a reboot and setup; it is not merely a placement flag. The expert
`--include-local` path is guarded by `CONFIRM_LOCAL_MEMMAP=YES` and is not part
of the four-bar result.

## FPGA programming is separate

FPGA programming and BMC power cycling are deliberately not part of
`setup_default.sh all`. When an authorized SPR1 operator needs to program a
provided image, first extract its matching POF beside the CDF, update CDF paths,
and then explicitly choose the CDF:

```bash
unzip program_script/chmu_ae_merge_SPL1.zip -d program_script
bash program_script/update_cdf_paths.sh
bash program_script/program_spr1.sh chmu_ae_merge_SPL1.cdf
```

`program_spr1.sh` derives the CDF path from the clone, but `QUARTUS_BIN` remains
a configurable host installation path (defaulting to the shared lab install).

After programming, power-cycle SPR1 with the command supplied separately by
the authorized system operator. This artifact intentionally does not include
a BMC power-cycle script or BMC credentials. Wait for SPR1 to finish booting,
reconnect to it, and only then run `set_default/setup_default.sh all`.

## Differences from the old manual scripts

The package preserves the final experimental state while removing several
transient or unsafe operations from the old host-specific scripts:

- It sets the final 2.0 GHz CPU frequency directly instead of briefly setting
  2.1 GHz first.
- It writes the benchmark-time CSR `0x70` value `0x180000000` directly instead
  of temporarily writing zero during setup.
- Threshold and epoch retain the original 32-bit CSR write width; the other
  configured CHMU values retain 64-bit writes, all with readback checks.
- It omits the missing `oom_hack/a.out` call and does not clear or disable
  kernel logs.
- PCI memory-space enable uses a masked update, and turbo disable uses a
  read-modify-write so unrelated control bits are preserved.

## Publication and licensing notes

See `THIRD_PARTY_NOTICES.md`. SPEC CPU2017 must be supplied under the reviewer's
own license. Confirm redistribution permission for components whose source has
no explicit license grant and for the FPGA images before making the repository
public.
