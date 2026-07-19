# AE2 – Memory Usage and Migration Traffic (Figure 4)

AE2 runs SPEC CPU2017 `gcc` with CHMU-Cache at thresholds 32 and 96 and plots
Local-memory usage, CXL-memory usage, and migration traffic over time. This
front section is the complete reviewer path. Detailed setup internals,
low-level runners, and recovery notes are preserved in the
[Appendix](#appendix-detailed-reference).

## Artifact at a glance

| Item | Reviewer path |
|---|---|
| Target | Figure 4, `gcc`, thresholds 32 and 96 |
| FPGA image | `chmu_ae_merge_SPL1` |
| Long-running step | Two benchmark/data-collection runs |
| Plotting | A separate processing-only step after both runs |
| Main output | `memory_usage_migration_traffic.{png,pdf}` |

## Quick start

Run commands from the normal reviewer account. Do not use `sudo -i` and do
not put `sudo` in front of an entire setup or benchmark command. The scripts
request privilege only for the host controls that need it.

### 1. Program the SPL1 FPGA image

On the FPGA programming server:

```bash
cd MICRO-2026-ARC/AE2
unzip -o program_script/chmu_ae_merge_SPL1.zip -d program_script
bash program_script/update_cdf_paths.sh
bash program_script/program_spr1.sh chmu_ae_merge_SPL1.cdf
```

Use the power-cycle command supplied separately by the authorized system
operator. BMC credentials are intentionally not included in this artifact.
Wait for SPR1 to boot, reconnect to it, and continue only after the custom
kernel and two NUMA nodes are visible.

```bash
uname -r
numactl -H
```

Expected kernel: `6.11.0-mig-offload+`. If SPR1 has not already been
provisioned, follow the separate [custom-kernel guide](../kernel/README.md)
before starting the reviewer path.

### 2. Check the external benchmark paths

SPEC CPU2017 is not redistributed. On SPR1, verify `SPEC_ROOT`, `SPEC_RUNCPU`,
and `SPEC_CONFIG` in:

```text
AE2/sw/config/benchmark_paths.env
```

### 3. Configure SPR1

```bash
cd MICRO-2026-ARC/AE2
bash set_default/setup_default.sh all
```

The setup detects the PCI BAR and NUMA topology, reuses the bundled kernel
modules, builds the four threshold managers, and applies the CPU/NUMA/CHMU
defaults. It does not start a benchmark.

### 4. Collect Figure 4 data

Plotting is deliberately skipped during the long-running measurements:

```bash
cd MICRO-2026-ARC/AE2
./sw/build_option_th32/run_fig4_th32.sh all yes --skip-plot
./sw/build_option_th96/run_fig4_th96.sh all yes --skip-plot
```

If a selected canonical output already exists, the noninteractive command
backs it up before rerunning it.

### 5. Generate the two plots from existing data

These commands do not rerun `gcc` or change FPGA state:

```bash
cd MICRO-2026-ARC/AE2

env PYTHONNOUSERSITE=1 \
  PYTHONPATH=/usr/lib/python3/dist-packages \
  ./sw/build_option_th32/run_fig4_th32.sh --skip-benchmark --yes

env PYTHONNOUSERSITE=1 \
  PYTHONPATH=/usr/lib/python3/dist-packages \
  ./sw/build_option_th96/run_fig4_th96.sh --skip-benchmark --yes
```

## Expected output

Each threshold writes its raw monitor log, converted CSV-like text, and plot
below its canonical run directory:

```text
sw/build_option_th32/output/<run-directory>/memory_usage_migration_traffic.png
sw/build_option_th96/output/<run-directory>/memory_usage_migration_traffic.png
```

The corresponding PDF files are written beside the PNG files. Threshold 32
should show more frequent migration traffic than threshold 96.

# Appendix: Detailed reference

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
| `sw/fig4` | Converts the raw gcc monitor log and plots Figure 4 memory/traffic traces | Post-processing |

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

The setup preflight checks for CMake, GCC/G++, Python 3, libnuma headers, PCI
utilities, numactl/numastat, msr-tools, PQoS, perf, cgroup v2, the bundled
kernel modules, and CPU frequency controls. It does not check Matplotlib;
Figure 4 checks it only immediately before PNG/PDF plotting. Benchmark data
collection and CSV conversion do not require it. Matching kernel headers
are checked only for a fallback module build. The reviewer account needs
passwordless or initially
interactive `sudo` access for modules, MSRs, sysfs, cgroups, PCI configuration,
and MMIO; benchmark runners refresh the authenticated timestamp without
prompting during long runs.
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
cd AE2
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

## Reproduce Figure 4 (gcc)

Figure 4 uses SPEC CPU2017 gcc (`502`) with eight copies, Cache-only CHMU
(`400000/400000`), a 1 ms polling argument, and a 10-second CXL-only warmup
before migration begins. The raw monitor interval is 5 seconds, matching the
original Figure 4 run; the converter spreads each observed counter delta into
one-second CSV rows. The paper panels are thresholds 32 and 96;
thresholds 16 and 64 are also provided for completeness.

The default command asks for confirmation before each of the benchmark,
conversion, and plotting steps:

```bash
./sw/build_option_th32/run_fig4_th32.sh
./sw/build_option_th96/run_fig4_th96.sh
```

To answer yes to every step without prompts, use the literal reviewer option
`all yes` (standard `--yes` and `--all-yes` aliases are also accepted):

```bash
./sw/build_option_th32/run_fig4_th32.sh all yes
./sw/build_option_th96/run_fig4_th96.sh all yes
```

To collect the raw log and CSV now without using Matplotlib, skip only the
plotting step:

```bash
./sw/build_option_th32/run_fig4_th32.sh --skip-plot
# Noninteractive data collection:
./sw/build_option_th32/run_fig4_th32.sh all yes --skip-plot
```

Each threshold has the corresponding entry point
`run_fig4_th16.sh`, `run_fig4_th32.sh`, `run_fig4_th64.sh`, or
`run_fig4_th96.sh` in its own build directory.

The threshold-32 canonical result directory is:

```text
sw/build_option_th32/output/32_400000_400000_1_502_mig_fig4_gcc_cache/
```

If that directory or its adjacent `.log` exists, interactive mode asks before
rerunning. Approval moves the old directory and log to `.bak`, then `.bak.1`,
`.bak.2`, and so on. `all yes` approves that backup automatically. To process
an existing canonical raw log without running gcc or moving anything, use:

```bash
./sw/build_option_th32/run_fig4_th32.sh --skip-benchmark
# Noninteractive reuse:
./sw/build_option_th32/run_fig4_th32.sh --skip-benchmark --yes
```

### Create the plotting environment

From the `AE2` directory, create this isolated environment once on SPR1. It is
stored under the reviewer account's home directory, outside the Git clone, and
therefore does not affect the system NumPy installation:

```bash
sudo apt update
sudo apt install -y python3-venv
python3 -m venv "$HOME/.venvs/micro-2026-arc-plot"
source "$HOME/.venvs/micro-2026-arc-plot/bin/activate"
python3 -m pip install --upgrade pip
python3 -m pip install -r sw/fig4/requirements.txt
python3 -c 'import sys, numpy, matplotlib; print(sys.executable); print(numpy.__version__, matplotlib.__version__)'
```

The expected versions are NumPy `1.26.4` and Matplotlib `3.8.4`. With the
environment still active, plot the previously collected threshold result
without rerunning gcc:

```bash
./sw/build_option_th32/run_fig4_th32.sh --skip-benchmark --yes
```

Use the matching threshold wrapper for threshold 96. In a new login shell,
activate the same environment again before plotting. Leave it after plotting
with `deactivate`; benchmark execution itself does not need this environment.

The pipeline leaves these files together in the result directory:

| File | Contents |
|---|---|
| `debug_monitor.log` | Raw periodic `/proc/vmstat` counters and `numastat -c base` tables |
| `debug_monitor.log.txt` | One-second CSV used by the plotter |
| `memory_usage_migration_traffic.png` | 300-DPI threshold plot, created by the optional plotting step |
| `memory_usage_migration_traffic.pdf` | Vector threshold plot, created by the optional plotting step |
| `sum_status_fail_MBs.sh` | Exact converter copied into the result for provenance |
| `plot_memory_migration.py` | Exact Matplotlib program copied into the result |

The converter labels `Total_node0_MB` as Local Memory and
`Total_node1_MB` as CXL Memory, so benchmark execution refuses a platform map
other than SPR1's Node 0 local / Node 1 CXL layout. Migration traffic is the
change in the system-wide `pgmigrate_success` counter, converted with a 4 KiB
page size. Keep SPR1 otherwise idle while collecting the trace: both
`numastat -c base` and `/proc/vmstat` intentionally reproduce the original
host-wide logging method.

The default plot axes match the paper comparison (`0--1000 s`, `0--8 GiB`,
and `0--800 MB/s`). For diagnosis only, the copied plotting program also
supports `--auto-x`; the reviewer wrapper always uses the fixed comparison
axes.

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
