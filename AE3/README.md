# MICRO 2026 ARC Artifact Evaluation: SPR1 setup and benchmarks

This directory is the portable SPR1 package for reproducing the CHMU
migration environment and running the GAPBS/SPEC CPU2017 experiments. All
artifact-local paths are derived from the Git clone. Only the separately
installed benchmark suites, graph datasets, and FPGA programming tool use
host-specific absolute paths.

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
| `sw/fig3` | Figure 3 orchestration, strict GAPBS/SPEC parsers, and normalized-performance plotter | Main evaluation |
| `sw/fig6` | Optional Cache/CMS epoch-sensitivity wrappers | Optional evaluation |
| `sw/optional` | Optional SPL1/SPL2/SPL4 sampling-ratio wrappers | Optional evaluation |

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
Figure plotting additionally requires Python 3 and matplotlib.
Setup changes host-wide CPU, NUMA, swap, PCI, and MMIO state, so use SPR1
exclusively. State-changing setup actions and benchmark entry points share an
exclusive lock and refuse to overlap with another ARC run; read-only
`check`/`status` may run without that lock.

## One-command setup

From the repository root of a fresh clone on SPR1:

```bash
cd AE3
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
`GAPBS_WEB_GRAPH`/`GAPBS_TWITTER_GRAPH` paths for GAPBS.

ANB (Auto NUMA Balancing) is provided by the SPR1 Linux kernel. It requires no
separate user-space package; the benchmark runner selects it through the
kernel NUMA-balancing control.

DAMON uses the `damo` installation and migration-policy JSON that are already
configured on SPR1. AE3 does not copy, install, or generate DAMO settings.
The software relationship and the `damo` submodule are documented in the
[ASPLOS-2025-M5 software README](https://github.com/ece-fast-lab/ASPLOS-2025-M5/blob/main/sw/README.md)
and [ASPLOS-2025-M5 `sw/damo`](https://github.com/ece-fast-lab/ASPLOS-2025-M5/tree/main/sw/damo).
If the existing SPR1 paths are not exported in the shell, set `DAMO_BIN` and
`DAMO_CONFIG` in `sw/config/benchmark_paths.env`; `DAMO_BIN` is detected
automatically when `damo` is on `PATH`.

## Main evaluation: reproduce Figure 3 with `pr_tw`

Figure 3 uses the SPL1 FPGA image (sampling every access). The scripts cannot
read back the compile-time sampling ratio, so the reviewer must confirm the
loaded image. After programming SPL1, power-cycling SPR1, cloning the artifact,
and completing setup, run from `AE3`:

```bash
bash set_default/setup_default.sh all
bash sw/fig3/run_fig3_gapbs.sh pr_tw
```

The second command asks before each long step. To accept every confirmation,
or to continue an interrupted sweep while retaining complete points, use:

```bash
bash sw/fig3/run_fig3_gapbs.sh pr_tw all yes
bash sw/fig3/run_fig3_gapbs.sh pr_tw --resume
```

It runs eleven points: Baseline, ANB, DAMON, four Cache thresholds, and four
CMS thresholds. Cache uses epoch `400000/400000`; CMS uses
`400001/400001`, whose set low bit selects the CMS implementation. The four
thresholds are `16`, `32`, `64`, and `96`. Baseline is fixed to the CXL node
with `numactl --membind`, matching the original Figure 3 run rather than the
common runner's more permissive two-node baseline default.

For GAPBS, the collector requires exactly ten anchored `Trial Time:` records
and computes the geometric mean of records 6--10. It deliberately ignores
GAPBS's all-ten arithmetic `Average Time`. The plot reports normalized
performance as `baseline_seconds / method_seconds`, so higher is better.
Outputs are written below:

```text
results/figure3/gapbs/pr_twitter/
  run_metadata.txt
  figure3_manifest.csv
  figure3_results.csv
  figure3_normalized_performance.png
  figure3_normalized_performance.pdf
  runs/
```

To regenerate only the CSV and plots from existing canonical logs:

```bash
bash sw/fig3/run_fig3_gapbs.sh pr_tw --skip-benchmark
```

Reuse/processing modes also require `runtime_summary.txt` to report successful
workload, manager, background-control, and tracker cleanup status.

See `FIGURE3_REPRODUCTION.md` for the exact method table, all benchmark
selectors, output validation rules, and optional experiments.

## Optional Figure 3 workloads

Other GAPBS combinations use either the short selector or two arguments:

```bash
bash sw/fig3/run_fig3_gapbs.sh bfs_tw
bash sw/fig3/run_fig3_gapbs.sh cc web
```

SPEC CPU2017 support is included but is optional for the reviewer. For gcc:

```bash
bash sw/fig3/run_fig3_spec.sh 502
```

The validated SPEC IDs are `502`, `505`, `507`, `527`, and `554`. The SPEC
collector requires a standalone `Run Complete` marker and exactly one
`; N total seconds elapsed` record; `--copies=8` is one eight-copy SPECrate
invocation, not eight repeated trials.

## Optional Figure 6 epoch sweep

Figure 6 uses SPL1, threshold 64, and Cache/CMS only. It does not run Baseline,
ANB, or DAMON. The complete GAPBS or SPEC sweeps are:

```bash
bash sw/fig6/run_fig6_epoch_gapbs.sh pr twitter
bash sw/fig6/run_fig6_epoch_spec.sh 502
```

Use `--method cache|cms|both`, `--epoch 1|10|100|1000|all`, `--resume`, or
`--yes` to narrow or automate the optional run. Cache epochs are
`400000`, `4000000`, `40000000`, and `400000000`; CMS uses the corresponding
odd values ending in `1`. Manager polling remains 1 ms for every epoch.

## Optional sampling-ratio runs

Sampling ratio is an FPGA compile-time setting. The following wrappers never
program a POF or reboot the server; they require the reviewer to declare and
confirm the already loaded SPL1/SPL2/SPL4 image and record that declaration in
the result manifest:

```bash
bash sw/optional/run_sampling_gapbs.sh pr twitter --sampling spl2
bash sw/optional/run_sampling_spec.sh 502 --sampling spl2 --threshold 32
```

The legacy GAPBS threshold mapping is SPL1=`64`, SPL2=`32`, and SPL4=`16`, so
the GAPBS wrapper supplies those defaults. SPEC requires `--threshold`
explicitly because the legacy SPEC SPL4 wrappers are inconsistent. See
`FIGURE3_REPRODUCTION.md` before using these optional commands.

## Run GAPBS

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

Dynamic Cache/CMS switching:

```bash
./sw/build_option_th16/run_test_indv_gap_400000_400001 bc twitter
```

Dynamic switching (`400000 != 400001`) is accepted only after both core and IMC
`perf` collectors produce usable samples. Collector startup/runtime failure
fails the manager and the benchmark command instead of silently changing the
algorithm. `CHMU_ALLOW_PREDICTOR_FALLBACK=1` enables the old duplicate-policy
fallback for debugging only; results from that override are not the reported
dynamic configuration.

The original convenience entry point is also retained; it runs Cache-only,
CMS-only, and dynamic switching sequentially:

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

Only `migration_manager` is started through `sudo`, because it opens BAR2 and
writes the root-only migration proc nodes. GAPBS/SPEC workloads remain under
the reviewer account. The root-only proc permissions are an artifact safety
hardening and do not change the migration request format.

The runner waits for a root-created readiness record, verifies the actual
manager PID and executable, resets/arms CHMU, and then releases the manager's
explicit start gate. It uses `SIGINT` plus a bounded TERM/KILL fallback, and
the manager retains each collector process-group ID so it can stop `perf` and
its children even if the group leader exits first. PMU temporary files are
kept in a root-owned mode-0700 per-run directory below `/run`, then ownership
is dropped before the files are archived into the run output. Manager,
background-control, tracker-disable, and workload failures are recorded and
propagated rather than reported as successful runs.

## Run SPEC CPU2017

The dynamic Cache/CMS wrapper accepts the numeric benchmark name; it defaults
to eight copies:

```bash
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
