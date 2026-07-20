# Optional configuration training and LOBO generation

Figure 11 uses the supplied cfg files under `pretrained/th*/gap`.
This document describes optional GAPBS retraining and suite-isolated LOBO generation.

The five training workloads are `bc_tw`, `bfs_tw`, `cc_tw`, `pr_tw`, and `pr_web`.

## Requirements

Complete the normal SPR1 setup before starting training.
Set `GAPBS_ROOT`, both graph paths, and `CHMU_PERF_BIN` in `sw/config/benchmark_paths.env`.
Training requires NumPy, Matplotlib, scikit-learn, and joblib.

Create an isolated Python environment if these packages are not available:

```bash
cd MICRO-2026-ARC/AE4
python3 -m venv "$HOME/.venvs/micro-2026-arc-ml"
source "$HOME/.venvs/micro-2026-arc-ml/bin/activate"
python3 -m pip install -r sw/ml/requirements.txt
```

## Run all five studies

The threshold-16 study runs 20 successful complete invocations for each workload, producing 100 history rows.

```bash
bash sw/ml/run_training_gapbs_all.sh \
  --threshold 16 --profile current-system all yes
```

Resume an interrupted study:

```bash
bash sw/ml/run_training_gapbs_all.sh \
  --threshold 16 --profile current-system --resume all yes
```

Check progress without running a benchmark:

```bash
bash sw/ml/run_training_gapbs_all.sh \
  --threshold 16 --profile current-system --status
```

Use `--fresh` only to back up all five existing studies and start again.
The all-five driver validates the histories and runs LOBO after the 100 rows complete.

## Training metric

Each GAPBS invocation runs ten trials.
Training records the printed arithmetic `Average Time` as one optimizer row.
Odd invocations use `400000/400001`, and even invocations use `400001/400000`.

This metric differs from Figure 11 reporting.
Figure 11 uses Trial Time positions 6–10 from five invocations and computes their geometric mean.

Training histories are stored below:

```text
results/retraining/current-system/training/th16/gapbs/<internal-key>/
```

## LOBO generation

LOBO generates each held-out GAPBS cfg from the other four GAPBS workloads without using SPEC data.

The all-five driver performs this step automatically.
To rerun it from the completed histories, use:

```bash
bash sw/ml/generate_lobo_configs.sh gap --threshold 16 \
  --source training --profile current-system
```

Generated GAPBS cfg files are written below:

```text
results/retraining/current-system/models/th16/gap/
```

Evaluate the generated profile without replacing the supplied cfg files:

```bash
bash sw/fig11/run_all_primary_th16.sh --resume \
  --model-root "$PWD/results/retraining/current-system/models/th16/gap" \
  --result-profile current-system
```

## Supplied cfg provenance

The supplied rank-1 cfg files were generated from accumulated suite-separated lab histories.
The historical row counts were not fixed at 20 per workload.

| Threshold | SPEC rows (`502/505/507/527/554`) | GAPBS rows (`bc/bfs/cc/pr_tw/pr_web`) |
|---:|---|---|
| 16 | 20 / 20 / 22 / 25 / 25 | 43 / 63 / 50 / 26 / 25 |
| 32 | 20 / 20 / 15 / 25 / 27 | 40 / 54 / 50 / 25 / 26 |
| 64 | 20 / 19 / 18 / 25 / 25 | 41 / 87 / 90 / 35 / 68 |
| 96 | 17 / 20 / 15 / 20 / 22 | 52 / 58 / 50 / 15 / 15 |

Portable suite-separated histories are provided under `reference_trials/th*`.
Regenerate threshold-16 GAPBS candidates from the reference CSV with:

```bash
bash sw/ml/generate_lobo_configs.sh gap --threshold 16 --source reference
```

The supplied cfg files remain unchanged unless `--replace-pretrained` is explicitly requested outside a named result profile.
Python and scikit-learn version differences can change the offline candidate ranking.
