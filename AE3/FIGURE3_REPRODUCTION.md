# Figure 3 reproduction and optional sensitivity runs

This manual starts after the SPL1 POF has been programmed and SPR1 has been
power-cycled. FPGA programming is intentionally separate from setup and from
every benchmark wrapper.

## Main reviewer path

Use the normal reviewer account for every command below. Do not use `sudo -i`
or run an entire benchmark command through `sudo`; the artifact itself raises
privilege only for the required host controls and migration manager.

### 1. Set up SPR1

From the repository clone after the reboot:

```bash
cd AE3
bash set_default/setup_default.sh all
```

`pr_tw` means GAPBS PageRank with the Twitter graph. This is the primary,
time-bounded Artifact Evaluation workload.

### 2. Collect data without plotting

The recommended automatic command runs all eleven cases and skips plotting:

```bash
bash sw/fig3/run_fig3_all_yes.sh
```

`run_fig3_all_yes.sh [workload] [options]` defaults to `pr_tw`. It supplies
automatic yes and `--skip-plot`, so the benchmark and CSV collection do not
depend on Matplotlib. The equivalent interactive command is:

```bash
bash sw/fig3/run_fig3_gapbs.sh pr_tw --case all --skip-plot
```

To run cases one at a time, select from `baseline`, `anb`, `damon`,
`cache16`, `cache32`, `cache64`, `cache96`, `cms16`, `cms32`, `cms64`, and
`cms96`:

```bash
bash sw/fig3/run_fig3_case.sh pr_tw baseline
bash sw/fig3/run_fig3_case.sh pr_tw cache32
bash sw/fig3/run_fig3_case.sh pr_tw cms96
```

The wrapper interface is
`run_fig3_case.sh <workload> <case> [options]`; the underlying runner also
accepts `--case <case|all>` directly. The case wrapper always skips plotting.
After all individual cases finish, run the all-case command with
`--resume --skip-plot` once to validate the full sweep and generate its CSV.

The two rerun modes have intentionally different meanings:


```bash
# Unconditionally accept rerunning selected cases. Existing canonical output
# is moved to the next .bak path.
bash sw/fig3/run_fig3_gapbs.sh pr_tw --case all all yes --skip-plot

# Reuse valid points and run only missing or incomplete points.
bash sw/fig3/run_fig3_gapbs.sh pr_tw --case all --resume --skip-plot
```

Use `--resume` after an interruption unless the existing valid points are
intentionally being replaced.

### 3. Plot the completed data later

The collectors use Python's standard library. Only the PNG/PDF step needs
NumPy and Matplotlib. On SPR1, select the compatible Ubuntu system packages
explicitly and run the processing-only wrapper:

```bash
env PYTHONNOUSERSITE=1 \
  PYTHONPATH=/usr/lib/python3/dist-packages \
  python3 -c 'import numpy, matplotlib; print(numpy.__version__, matplotlib.__version__)'

env PYTHONNOUSERSITE=1 \
  PYTHONPATH=/usr/lib/python3/dist-packages \
  bash sw/fig3/plot_fig3.sh pr_tw
```

`plot_fig3.sh <workload> [options]` uses `--skip-benchmark` internally. It
validates the existing canonical logs and never moves output, runs a workload,
or touches hardware.

If the system-package import fails, create and activate a virtual environment
only for plotting:

```bash
sudo apt install -y python3-venv
python3 -m venv "$HOME/.venvs/micro-2026-arc-plot"
source "$HOME/.venvs/micro-2026-arc-plot/bin/activate"
python3 -m pip install --upgrade pip
python3 -m pip install -r sw/fig3/requirements.txt
bash sw/fig3/plot_fig3.sh pr_tw
deactivate
```

## Figure 3 points

| Order | Label | Common-runner mode | Threshold | Epoch A/B | Placement/migration policy |
|---:|---|---|---:|---:|---|
| 1 | Baseline | `baseline` | 16 | `400000/400000` | CXL node only, `numactl --membind`, demotion off |
| 2 | ANB | `anb` | 16 | `400000/400000` | SPR1 Linux-kernel Auto NUMA Balancing |
| 3 | DAMON | `damon` | 16 | `400000/400000` | DAMON `migrate_hot`/`migrate_cold` configuration |
| 4--7 | Cache-16/32/64/96 | `mig` | 16/32/64/96 | `400000/400000` | Cache-based CHMU, even epoch |
| 8--11 | CMS-16/32/64/96 | `mig` | 16/32/64/96 | `400001/400001` | CMS-based CHMU, odd epoch |

The threshold attached to Baseline/ANB/DAMON only selects a stable manager
directory name; CHMU tracking remains disabled in those modes. Workload CPUs
are 0--7, the migration/control CPU is 20, manager polling is 1 ms, and GAPBS
runs ten trials with eight OpenMP threads.

ANB is a feature of the SPR1 Linux kernel and needs no separate user-space
software installation. The runner enables the kernel NUMA-balancing control
only for the ANB comparison point.

DAMON uses the `damo` executable and migration-policy JSON already installed
and configured on SPR1. AE3 does not vendor or modify that installation. The
source relationship is documented by the
[ASPLOS-2025-M5 software README](https://github.com/ece-fast-lab/ASPLOS-2025-M5/blob/main/sw/README.md)
and its [`sw/damo` submodule](https://github.com/ece-fast-lab/ASPLOS-2025-M5/tree/main/sw/damo).
Set `DAMO_BIN` and `DAMO_CONFIG` in `sw/config/benchmark_paths.env` only if the
existing SPR1 paths are not already available through `PATH`/the environment.

## Log parsing and graph values

GAPBS and SPEC use separate parsers.

For GAPBS, the parser:

1. Matches complete lines beginning `Trial Time:`.
2. Requires exactly ten positive finite values.
3. Computes `exp(sum(log(trial_6 ... trial_10)) / 5)`.
4. Ignores `Average Time`, which is an arithmetic average of all ten trials.

For SPEC, the parser requires both a standalone `Run Complete` line and
exactly one line ending with `; N total seconds elapsed`. It does not assume a
fixed line number. The eight SPECrate copies form one run, so there is no
last-five aggregation for SPEC.

Every method is normalized to the same workload's Baseline:

```text
normalized_performance = baseline_seconds / method_seconds
normalized_runtime     = method_seconds / baseline_seconds
```

The plot uses normalized performance; both values, the raw runtime, parser
name, selected GAPBS trials, log path, byte size, and SHA-256 are retained in
`figure3_results.csv`. `run_metadata.txt` records whether the SPL1 declaration
was confirmed for a benchmark run or omitted in processing-only mode.

## Selecting another benchmark

All GAPBS algorithms and datasets are optional:

```bash
bash sw/fig3/run_fig3_gapbs.sh bc_tw --skip-plot
bash sw/fig3/run_fig3_gapbs.sh bfs_web --skip-plot
bash sw/fig3/run_fig3_gapbs.sh cc twitter --skip-plot
bash sw/fig3/run_fig3_gapbs.sh pr web --skip-plot
```

The short database suffixes are `tw` and `web`. SPEC is also optional:

```bash
bash sw/fig3/run_fig3_spec.sh 502 --skip-plot   # gcc_r
bash sw/fig3/run_fig3_spec.sh 505 --skip-plot   # mcf_r
bash sw/fig3/run_fig3_spec.sh 507 --skip-plot   # cactuBSSN_r
bash sw/fig3/run_fig3_spec.sh 527 --skip-plot   # cam4_r
bash sw/fig3/run_fig3_spec.sh 554 --skip-plot   # roms_r
```

Benchmark suites and Twitter/web graphs are not distributed with this
artifact. Configure their SPR1 absolute paths in
`sw/config/benchmark_paths.env` before starting.

## Optional Figure 6 epoch sensitivity

Keep SPL1 loaded. Figure 6 fixes threshold 64 and compares Cache and CMS at
four epoch lengths; it intentionally omits Baseline, ANB, and DAMON.

| Epoch length | Cache CSR value | CMS CSR value |
|---:|---:|---:|
| 1 ms | `400000` | `400001` |
| 10 ms | `4000000` | `4000001` |
| 100 ms | `40000000` | `40000001` |
| 1000 ms | `400000000` | `400000001` |

```bash
# All eight pr/twitter points.
bash sw/fig6/run_fig6_epoch_gapbs.sh pr twitter

# Only CMS at 100 ms.
bash sw/fig6/run_fig6_epoch_gapbs.sh pr twitter --method cms --epoch 100

# Optional SPEC epoch sweep.
bash sw/fig6/run_fig6_epoch_spec.sh 502 --resume
```

The manager poll argument stays at 1 ms; `--epoch` selects only the hardware
epoch. The odd CMS values are intentional: a filename tag cannot select the
hardware implementation. `run_manifest.txt` records every point as completed,
reused, or skipped by the reviewer.

## Optional FPGA sampling sensitivity

SPL1, SPL2, and SPL4 sample one of every 1, 2, and 4 accesses, respectively.
This parameter is compiled into the POF and has no runtime CSR identification.
For every sampling point:

1. Program the matching POF separately.
2. Power-cycle SPR1.
3. Run setup again if required after reboot.
4. Invoke the workload-only wrapper and confirm the loaded image.

```bash
# Legacy GAPBS mapping: SPL2 uses threshold 32.
bash sw/optional/run_sampling_gapbs.sh pr twitter --sampling spl2

# Select only Cache for SPL4 (default GAPBS threshold 16).
bash sw/optional/run_sampling_gapbs.sh pr twitter \
  --sampling spl4 --method cache

# SPEC requires an explicit threshold due to inconsistent legacy SPL4 scripts.
bash sw/optional/run_sampling_spec.sh 502 \
  --sampling spl4 --threshold 16 --method both
```

These wrappers never call Quartus, power-cycle the server, or claim to detect
the image. They write the reviewer-declared sampling image and threshold into
`results/sampling/.../run_manifest.txt`, together with each point's completed,
reused, or skipped status.
