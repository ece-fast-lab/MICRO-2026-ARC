# Optional configuration training and LOBO generation

The normal Figure 11 reproduction uses the supplied files under
`pretrained/th*/{gap,spec}`. Reviewers should skip this directory unless they
want to inspect or rerun the much longer configuration-selection workflow.

## Workloads

| Suite | Reviewer alias | Internal key |
|---|---|---|
| GAPBS | `bc_tw`, `bfs_tw`, `cc_tw`, `pr_tw`, `pr_web` | `bc_twitter`, `bfs_twitter`, `cc_twitter`, `pr_twitter`, `pr_web` |
| SPEC CPU2017 | `gcc`, `mcf`, `cactuB`, `cam4`, `roms` | `502`, `505`, `507`, `527`, `554` |

Every threshold (16, 32, 64, and 96) has a rank-1 pretrained cfg for all ten
workloads. Figure 11 uses GAPBS, but the requested SPEC training and cfg files
are included for completeness.

## What runs online and offline

The offline Random Forest does not run in the benchmark process. It learns a
surrogate from configuration parameters and measured runtimes, then proposes
candidate `.cfg` files. Each cfg contains 11 scale/bias/margin values and two
vote-hysteresis values. At runtime, `migration_manager` reads that text file
through the absolute `CHMU_MODEL_PATH` and applies it to its fixed online
predictor. Offline `.joblib` models are therefore unnecessary for Figure 11 and
are not distributed.

## Stage A: optional current-system GAPBS trials

Run these commands from the `AE4` directory after programming SPL1, power
cycling SPR1, and completing the normal setup:

```bash
cd MICRO-2026-ARC/AE4
bash set_default/setup_default.sh all

python3 -m venv "$HOME/.venvs/micro-2026-arc-ml"
source "$HOME/.venvs/micro-2026-arc-ml/bin/activate"
python3 -m pip install -r sw/ml/requirements.txt
```

If SPR1 already provides all four packages as distribution packages, a virtual
environment is unnecessary. Verify and use that environment instead:

```bash
env PYTHONNOUSERSITE=1 PYTHONPATH=/usr/lib/python3/dist-packages \
  python3 -c 'import numpy, matplotlib, sklearn, joblib'
export PYTHONNOUSERSITE=1
export PYTHONPATH=/usr/lib/python3/dist-packages
```

Verify `GAPBS_ROOT`, both the Twitter and Web graph inputs, and the custom
`CHMU_PERF_BIN` in `sw/config/benchmark_paths.env`. The full threshold-16 study
is one command:

```bash
bash sw/ml/run_training_gapbs_all.sh \
  --threshold 16 --profile current-system all yes
```

This runs `bc_tw`, `bfs_tw`, `cc_tw`, `pr_tw`, and `pr_web` sequentially. Each
workload contributes exactly 20 successful complete GAPBS invocations, for 100
history rows total. Every invocation runs GAPBS with `-n10`, so the study emits
1,000 individual `Trial Time` values but uses one optimizer row per invocation.

The profile driver refuses to replace an existing study unless the action is
explicit. After an interruption or a real benchmark failure, preserve all
validated rows and continue both partially started and not-yet-started
workloads with:

```bash
bash sw/ml/run_training_gapbs_all.sh \
  --threshold 16 --profile current-system --resume all yes
```

Use `--status` to print row counts without touching hardware. Use `--fresh`
only when all five histories should be backed up to `.bakN` and restarted.
Failed runs and runs whose workload, cleanup, cfg-load, or adaptive-policy
checks fail are not appended to history.

GAPBS training optimizes the printed `Average Time`, which is the arithmetic
mean of all ten trials in one invocation. SPEC training optimizes the single
`total seconds elapsed` value. This differs intentionally from the Figure 11
reporting metric, which is a 25-sample geometric mean of Trial Time positions
6--10 from five invocations.

The optimizer invokes the same host-locked benchmark runner sequentially. It
waits 30 seconds between successful invocations by default. Only the runner's
explicit shared-lock-busy signal is retried, for up to 300 seconds; workload,
perf, manager, and validation failures stop immediately. Change the idle time
with `--trial-interval-sec` and the bounded lock wait with
`TRAINING_LOCK_RETRY_INTERVAL_SEC` and `TRAINING_LOCK_RETRY_TIMEOUT_SEC`.

The candidate procedure follows the earlier study:

1. Start from the shipped cfg for the same threshold and workload (or an
   explicit `--seed-model-path`).
2. Before six samples, use local mutations with occasional global samples.
3. From six samples onward, fit a 200-tree Random Forest surrogate and choose
   among 96 local mutations and 32 random candidates.
4. Use epoch order `400000/400001` for odd trials and reverse it for even
   trials.

The single-workload wrappers remain available for focused studies:

```bash
bash sw/ml/run_training_gapbs.sh bc_tw \
  --threshold 16 --profile current-system --resume all yes
bash sw/ml/run_training_spec.sh gcc --threshold 16
```

The GAPBS histories are stored below
`results/retraining/current-system/training/th16/gapbs/<internal-key>/`.
Each directory contains `history.jsonl`, 20 candidate cfgs, `best.cfg`,
best-run metadata, and the validated raw run directories.

## Stage B: suite-isolated LOBO

LOBO never mixes the suites. For example, the held-out `502` cfg is trained on
only `505/507/527/554`; a held-out GAPBS cfg is trained on only the other four
GAPBS workloads.

The all-five driver validates every JSON history and performs Stage B
automatically. To regenerate it manually from the same profile:

```bash
bash sw/ml/generate_lobo_configs.sh gap --threshold 16 \
  --source training --profile current-system
```

The wrapper refuses incomplete, noncontiguous, mixed-host/kernel, or
wrong-threshold histories. LOBO diagnostics and top-10 candidates are written
under `results/retraining/current-system/lobo/th16/gap`. The five rank-1
proposals and a provenance/hash manifest are staged atomically under:

```text
results/retraining/current-system/models/th16/gap/
```

These files are surrogate-predicted candidates, not proven improvements on the
held-out workload. Evaluate them without changing the shipped reproduction
baseline:

```bash
bash sw/fig11/run_all_primary_th16.sh --resume \
  --model-root "$PWD/results/retraining/current-system/models/th16/gap" \
  --result-profile current-system
```

The selected cfg is frozen by SHA-256 in the isolated result profile. Plot it
with the same two model/profile options:

```bash
env PYTHONNOUSERSITE=1 PYTHONPATH=/usr/lib/python3/dist-packages \
  bash sw/fig11/plot_fig11_primary_combined.sh --threshold 16 \
  --model-root "$PWD/results/retraining/current-system/models/th16/gap" \
  --result-profile current-system
```

The normal Figure 11 command continues to use `sw/ml/pretrained`; profile
generation never overwrites those files.

## Supplied cfg provenance

The shipped cfgs were copied unchanged from the rank-1 suite-separated LOBO
outputs produced from the available accumulated lab histories. Those legacy
histories did not contain exactly 20 rows per workload:

| Threshold | SPEC rows (`502/505/507/527/554`) | GAPBS rows (`bc/bfs/cc/pr_tw/pr_web`) |
|---:|---|---|
| 16 | 20 / 20 / 22 / 25 / 25 | 43 / 63 / 50 / 26 / 25 |
| 32 | 20 / 20 / 15 / 25 / 27 | 40 / 54 / 50 / 25 / 26 |
| 64 | 20 / 19 / 18 / 25 / 25 | 41 / 87 / 90 / 35 / 68 |
| 96 | 17 / 20 / 15 / 20 / 22 | 52 / 58 / 50 / 15 / 15 |

The historical LOBO code included every row containing a model and parsed
runtime; it did not filter the recorded return-code field. The supplied cfgs
remain unchanged for fidelity. The new AE4 trial path is stricter and records
only fully validated successes.

Portable suite-separated CSV snapshots are under `reference_trials/th*` and
can be used to inspect the LOBO procedure without running benchmarks:

```bash
bash sw/ml/generate_lobo_configs.sh gap --threshold 16 --source reference
```

The CSV serializes parameters to ten significant digits, so regenerated cfgs
can differ from the supplied full-history cfgs in insignificant final decimal
places. With the same supported Python stack, the suite split and candidate
selection procedure are deterministic.

Optional LOBO dependencies are NumPy, Matplotlib, scikit-learn, and joblib.
The supplied legacy outputs identify scikit-learn 1.7.2; using another version
can also change offline candidate ranking, which is another reason the normal
reviewer path consumes the distributed cfg directly.

The offline parser/schema tests do not run a benchmark:

```bash
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s sw/ml/tests -v
```
