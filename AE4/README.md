# MICRO 2026 ARC Artifact Evaluation: Figure 11

This directory is the portable SPR1 package for reproducing Figure 11: a
four-bar comparison of CXL-only, static CHMU-Cache, static CHMU-CMS, and the
adaptive Cache/CMS policy. The primary reviewer workloads are GAPBS `bc_tw`,
`bfs_tw`, and `pr_tw`. All artifact-local paths are derived from the Git clone;
only separately installed benchmarks, graph datasets, and the FPGA tool use
host-specific absolute paths.

The short step-by-step procedure is in
[`FIGURE11_REPRODUCTION.md`](FIGURE11_REPRODUCTION.md). The optional 20-trial
training and suite-isolated Leave-One-Benchmark-Out workflow is documented in
[`sw/ml/README.md`](sw/ml/README.md).

## Reviewer quick path

After the SPL1 POF has been programmed and SPR1 has been power-cycled:

```bash
cd MICRO_2026_ARC/AE4
bash set_default/setup_default.sh all

# Select one primary workload.
bash sw/fig11/run_fig11_th16.sh bc_tw
# bash sw/fig11/run_fig11_th16.sh bfs_tw
# bash sw/fig11/run_fig11_th16.sh pr_tw
```

Use `all yes` after the workload to accept all prompts, `--resume` to reuse
valid completed invocations, or `--skip-benchmark` to validate and plot
existing canonical logs only. The command runs five complete GAPBS invocations
for each of four methods. From every invocation it selects Trial Time 6--10,
giving 25 samples per method, and plots the geometric-mean normalized
performance:

```text
CXL-only geometric-mean time / method geometric-mean time
```

Values above `1.0` are better. Results are stored below
`results/figure11/th16/<workload>/` as raw-run manifests, selected-sample CSV,
summary CSV, metadata, PNG, and PDF.

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
| `sw/fig11` | Five-repeat runner, strict 25-sample collector, and Figure 11 plotter | Figure 11 |
| `sw/fig11_spec` | Optional five-repeat SPEC four-bar runner and SPEC log collector | Optional extension |
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
five repetitions, and applies the 25-sample metric.

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

Dynamic switching (`400000 != 400001`) is accepted only after both core and IMC
`perf` collectors produce usable samples. Collector startup/runtime failure
fails the manager and the benchmark command instead of silently changing the
algorithm. `CHMU_ALLOW_PREDICTOR_FALLBACK=1` enables the old duplicate-policy
fallback for debugging only; results from that override are not the reported
dynamic configuration.

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

For optional fresh studies, these entry points target 20 successful executions
per workload and support thresholds 16, 32, 64, and 96:

```bash
bash sw/ml/run_training_gapbs.sh bc_tw --threshold 16
bash sw/ml/run_training_spec.sh gcc --threshold 16
```

After all five workloads in one suite have exactly 20 successful histories,
generate suite-isolated LOBO candidates with:

```bash
bash sw/ml/generate_lobo_configs.sh gap --threshold 16 --source training
```

The optional offline tools need NumPy, Matplotlib, scikit-learn, and joblib.
The supplied runtime cfg path needs none of those ML packages; only Matplotlib
is required to draw the Figure 11 output. Full provenance, workload mappings,
and the explicit cfg-replacement command are in `sw/ml/README.md`.

## Optional selectable SPEC comparison

Figure 11 and the reviewer quick path remain GAPBS-only. For completeness, the
same four policies can also be run for one restricted SPEC workload with the
corresponding SPEC-only LOBO cfg:

```bash
bash sw/run_figure11_benchmark.sh spec gcc --threshold 16
# Other choices: mcf, cactuB, cam4, roms
```

The same dispatcher accepts GAPBS, for example
`bash sw/run_figure11_benchmark.sh gapbs bc_tw --threshold 16`. The optional
SPEC path runs five complete invocations per method, selects the final anchored
`total seconds elapsed` value from each invocation, computes a five-sample
geometric mean, and plots `CXL-only time / method time`. This metric is kept
separate from the reported GAPBS 25-value metric. Threshold-specific SPEC
wrappers are under `sw/fig11_spec/run_fig11_spec_th{16,32,64,96}.sh`.

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
