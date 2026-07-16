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

## Stage A: optional fresh per-workload trials

Dependencies: Python 3.9+ and scikit-learn. Run each desired workload with the
same SPL1 image used for Figure 11:

```bash
bash sw/ml/run_training_gapbs.sh bc_tw --threshold 16
bash sw/ml/run_training_spec.sh gcc --threshold 16
```

The default target is exactly 20 successful executions in a fresh study. It is
a total target, not “20 more”: `--resume` continues only up to 20. Without
`--resume`, an existing study is backed up to `.bakN` after confirmation;
`--fresh` requests that backup explicitly. Failed runs and runs whose workload,
cleanup, cfg-load, or adaptive-policy checks fail are not appended to history.

GAPBS training optimizes the printed `Average Time`, which is the arithmetic
mean of all ten trials in one invocation. SPEC training optimizes the single
`total seconds elapsed` value. This differs intentionally from the Figure 11
reporting metric, which is a 25-sample geometric mean of Trial Time positions
6--10 from five invocations.

The 20-trial optimizer invokes the same host-locked benchmark runner
sequentially. Each runner explicitly unlocks and closes the shared ARC lock
after cleanup, before the Python subprocess returns, so a completed trial
cannot self-block the next trial through an inherited logging process. No
artificial inter-trial delay or automatic retry is therefore applied. A real
concurrent ARC command still stops the optional study instead of being treated
as a training result; rerun the training command with `--resume` after that
command exits. Only fully validated completed trials are retained in history.

The candidate procedure follows the earlier study:

1. Start from the workload seed cfg.
2. Before six samples, use local mutations with occasional global samples.
3. From six samples onward, fit a 200-tree Random Forest surrogate and choose
   among 96 local mutations and 32 random candidates.
4. Use epoch order `400000/400001` for odd trials and reverse it for even
   trials.

To create a full fresh GAPBS dataset at one threshold, run all five aliases;
do the same separately for the five SPEC aliases if SPEC cfgs are desired.

```bash
for b in bc_tw bfs_tw cc_tw pr_tw pr_web; do
  bash sw/ml/run_training_gapbs.sh "$b" --threshold 16 all yes
done

for b in gcc mcf cactuB cam4 roms; do
  bash sw/ml/run_training_spec.sh "$b" --threshold 16 all yes
done
```

## Stage B: suite-isolated LOBO

LOBO never mixes the suites. For example, the held-out `502` cfg is trained on
only `505/507/527/554`; a held-out GAPBS cfg is trained on only the other four
GAPBS workloads.

Generate cfgs from a complete set of five fresh, 20-row histories:

```bash
bash sw/ml/generate_lobo_configs.sh gap --threshold 16 --source training
bash sw/ml/generate_lobo_configs.sh spec --threshold 16 --source training
```

The wrapper refuses `--source training` unless every workload in that suite has
exactly 20 successful rows. Outputs, including top-10 candidates and validation
figures, are written under `results/lobo/th*/<suite>`.

After reviewing the generated output, explicitly replace the five supplied
rank-1 cfgs for that suite if desired:

```bash
bash sw/ml/generate_lobo_configs.sh gap --threshold 16 \
  --source training --replace-pretrained
```

This replacement is never performed by the normal Figure 11 command.
The Figure 11 runner freezes the selected file in a SHA-256-addressed result
snapshot before running. If a supplied cfg is replaced later, `--resume` will
reuse static results but will reject adaptive repetitions made with the older
snapshot; `--skip-benchmark` likewise refuses mixed-provenance output.

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
