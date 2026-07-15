#!/usr/bin/env python3
"""Suite-isolated leave-one-benchmark-out Random Forest cfg proposal.

For each benchmark in one suite, train a RandomForestRegressor using only the
other benchmarks' history. Input may be a fresh ``ml_training`` tree or one of
the portable reference CSV files. Features are cfg parameters only, and the
target is per-benchmark seed-normalized execution time. The held-out benchmark
is used only for leakage-free evaluation of historical trial ranking, not for
training or candidate generation.
"""

from __future__ import annotations

import argparse
import csv
import inspect
import json
import math
import os
import random
import sys
import time
import warnings
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Optional

os.environ.setdefault("PANDAS_USE_NUMEXPR", "0")
os.environ.setdefault("PANDAS_USE_BOTTLENECK", "0")
sys.modules.setdefault("numexpr", None)
sys.modules.setdefault("bottleneck", None)
warnings.filterwarnings("ignore", message="Unable to import Axes3D.*", category=UserWarning)

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np
from joblib import dump
from sklearn.ensemble import RandomForestRegressor
from sklearn.inspection import permutation_importance
from sklearn.metrics import mean_absolute_error, mean_squared_error, r2_score


FLOAT_FIELDS = [
    "bw_scale",
    "ipc_scale",
    "mpki_scale",
    "llc_mpki_scale",
    "mem_bound_scale",
    "queue_scale",
    "dup_rate_scale",
    "max_dup_scale",
    "dtlb_mpki_scale",
    "bias",
    "score_margin",
]
INT_FIELDS = ["consecutive_votes_required", "consecutive_votes_required_weak"]
PARAM_FIELDS = FLOAT_FIELDS + INT_FIELDS

DEFAULT_MODEL = {
    "bw_scale": 2800.0,
    "ipc_scale": 1.40,
    "mpki_scale": 2.50,
    "llc_mpki_scale": 2.00,
    "mem_bound_scale": 30.0,
    "queue_scale": 48.0,
    "dup_rate_scale": 0.14,
    "max_dup_scale": 2.50,
    "dtlb_mpki_scale": 1.00,
    "bias": 0.00,
    "score_margin": 0.20,
    "consecutive_votes_required": 2,
    "consecutive_votes_required_weak": 3,
}

PARAM_BOUNDS = {
    "bw_scale": (800.0, 8000.0),
    "ipc_scale": (0.2, 6.0),
    "mpki_scale": (0.1, 20.0),
    "llc_mpki_scale": (0.1, 20.0),
    "mem_bound_scale": (5.0, 95.0),
    "queue_scale": (1.0, 256.0),
    "dup_rate_scale": (0.001, 2.0),
    "max_dup_scale": (1.0, 16.0),
    "dtlb_mpki_scale": (0.05, 10.0),
    "bias": (-2.5, 2.5),
    "score_margin": (0.01, 1.5),
    "consecutive_votes_required": (1, 5),
    "consecutive_votes_required_weak": (2, 8),
}

MUTATION_SIGMA = {
    "bw_scale": 0.18,
    "ipc_scale": 0.18,
    "mpki_scale": 0.18,
    "llc_mpki_scale": 0.18,
    "mem_bound_scale": 0.16,
    "queue_scale": 0.22,
    "dup_rate_scale": 0.30,
    "max_dup_scale": 0.22,
    "dtlb_mpki_scale": 0.20,
    "bias": 0.20,
    "score_margin": 0.18,
}


@dataclass
class TrialRow:
    benchmark: str
    trial_index: int
    average_time: float
    normalized_time: float
    seed_time: float
    proposal_kind: str
    return_code: Optional[int]
    params: dict[str, float]


def natural_benchmark_sort(name: str) -> tuple[int, str]:
    return (0, name) if name[:1].isdigit() else (1, name)


def log(message: str, path: Path) -> None:
    line = f"[{time.strftime('%Y-%m-%d %H:%M:%S')}] {message}"
    print(line)
    with path.open("a") as handle:
        handle.write(line + "\n")


def ensure_dirs(out_dir: Path) -> dict[str, Path]:
    dirs = {
        "root": out_dir,
        "scripts": out_dir / "scripts",
        "data": out_dir / "data",
        "results": out_dir / "results",
        "figures": out_dir / "figures",
        "models": out_dir / "models",
        "cfg": out_dir / "generated_cfg",
        "logs": out_dir / "logs",
    }
    for directory in dirs.values():
        directory.mkdir(parents=True, exist_ok=True)
    return dirs


def normalize_model(model: dict[str, Any]) -> dict[str, float]:
    merged = dict(DEFAULT_MODEL)
    merged.update(model or {})
    params: dict[str, float] = {}
    for field in FLOAT_FIELDS:
        lo, hi = PARAM_BOUNDS[field]
        params[field] = min(hi, max(lo, float(merged[field])))
    strong = int(round(float(merged["consecutive_votes_required"])))
    weak = int(round(float(merged.get("consecutive_votes_required_weak", strong + 1))))
    strong = int(min(PARAM_BOUNDS["consecutive_votes_required"][1], max(PARAM_BOUNDS["consecutive_votes_required"][0], strong)))
    weak = int(min(PARAM_BOUNDS["consecutive_votes_required_weak"][1], max(strong + 1, weak)))
    params["consecutive_votes_required"] = float(strong)
    params["consecutive_votes_required_weak"] = float(weak)
    return params


def filter_benchmarks(benchmarks: list[str], benchmark_set: str) -> list[str]:
    spec = [name for name in benchmarks if name[:1].isdigit()]
    gap = [name for name in benchmarks if not name[:1].isdigit()]
    if benchmark_set == "all":
        return benchmarks
    if benchmark_set == "spec":
        return spec
    if benchmark_set == "gap":
        return gap
    wanted = [item.strip() for item in benchmark_set.split(",") if item.strip()]
    missing = sorted(set(wanted) - set(benchmarks))
    if missing:
        raise ValueError(f"Unknown benchmark(s) in --benchmark-set: {','.join(missing)}")
    return [name for name in benchmarks if name in wanted]


def load_trials(ml_root: Path, benchmark_set: str) -> tuple[list[str], list[TrialRow]]:
    training_root = ml_root / "ml_training"
    if not training_root.exists():
        training_root = ml_root
    if not training_root.exists():
        raise FileNotFoundError(f"Missing training-history directory: {training_root}")
    benchmarks = sorted(
        [path.name for path in training_root.iterdir() if (path / "history.jsonl").exists()],
        key=natural_benchmark_sort,
    )
    selected_benchmarks = filter_benchmarks(benchmarks, benchmark_set)
    rows: list[TrialRow] = []
    for benchmark in selected_benchmarks:
        history_path = training_root / benchmark / "history.jsonl"
        records = [json.loads(line) for line in history_path.read_text().splitlines() if line.strip()]
        if not records:
            continue
        seed_time = float(records[0]["average_time"])
        for record in records:
            if "average_time" not in record or "model" not in record:
                continue
            average_time = float(record["average_time"])
            rows.append(
                TrialRow(
                    benchmark=benchmark,
                    trial_index=int(record.get("trial_index", 0)),
                    average_time=average_time,
                    normalized_time=average_time / seed_time,
                    seed_time=seed_time,
                    proposal_kind=str(record.get("proposal_kind", "")),
                    return_code=record.get("return_code"),
                    params=normalize_model(record["model"]),
                )
            )
    return selected_benchmarks, rows


def load_trials_csv(path: Path, benchmark_set: str) -> tuple[list[str], list[TrialRow]]:
    if not path.is_file():
        raise FileNotFoundError(f"Missing input CSV: {path}")
    with path.open(newline="") as handle:
        records = list(csv.DictReader(handle))
    if not records:
        raise ValueError(f"Input CSV contains no trial rows: {path}")
    required = {
        "benchmark",
        "trial_index",
        "average_time",
        "normalized_time",
        "seed_time",
        "proposal_kind",
        *PARAM_FIELDS,
    }
    missing = sorted(required - set(records[0]))
    if missing:
        raise ValueError(f"Input CSV is missing columns: {','.join(missing)}")

    available = sorted({record["benchmark"] for record in records}, key=natural_benchmark_sort)
    selected_benchmarks = filter_benchmarks(available, benchmark_set)
    selected = set(selected_benchmarks)
    rows: list[TrialRow] = []
    for record in records:
        benchmark = record["benchmark"]
        if benchmark not in selected:
            continue
        raw_return_code = record.get("return_code", "").strip()
        params = normalize_model({field: record[field] for field in PARAM_FIELDS})
        rows.append(
            TrialRow(
                benchmark=benchmark,
                trial_index=int(record["trial_index"]),
                average_time=float(record["average_time"]),
                normalized_time=float(record["normalized_time"]),
                seed_time=float(record["seed_time"]),
                proposal_kind=record.get("proposal_kind", ""),
                return_code=int(raw_return_code) if raw_return_code else None,
                params=params,
            )
        )
    return selected_benchmarks, rows


def write_dataset(rows: list[TrialRow], path: Path) -> None:
    fieldnames = [
        "benchmark",
        "trial_index",
        "average_time",
        "normalized_time",
        "seed_time",
        "proposal_kind",
        "return_code",
        *PARAM_FIELDS,
    ]
    with path.open("w", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=fieldnames)
        writer.writeheader()
        for row in rows:
            payload: dict[str, Any] = {
                "benchmark": row.benchmark,
                "trial_index": row.trial_index,
                "average_time": f"{row.average_time:.10g}",
                "normalized_time": f"{row.normalized_time:.10g}",
                "seed_time": f"{row.seed_time:.10g}",
                "proposal_kind": row.proposal_kind,
                "return_code": "" if row.return_code is None else row.return_code,
            }
            payload.update({field: f"{row.params[field]:.10g}" for field in PARAM_FIELDS})
            writer.writerow(payload)


def row_matrix(rows: list[TrialRow]) -> tuple[np.ndarray, np.ndarray]:
    x = np.array([[row.params[field] for field in PARAM_FIELDS] for row in rows], dtype=float)
    y = np.array([row.normalized_time for row in rows], dtype=float)
    return x, y


def make_rf(random_state: int, n_estimators: int, n_jobs: int) -> RandomForestRegressor:
    return RandomForestRegressor(
        n_estimators=n_estimators,
        min_samples_leaf=2,
        max_features="sqrt",
        bootstrap=True,
        random_state=random_state,
        n_jobs=n_jobs,
    )


def vector_to_params(vector: np.ndarray) -> dict[str, float]:
    params = {field: float(vector[i]) for i, field in enumerate(PARAM_FIELDS)}
    strong = int(round(params["consecutive_votes_required"]))
    weak = int(round(params["consecutive_votes_required_weak"]))
    strong = int(min(PARAM_BOUNDS["consecutive_votes_required"][1], max(PARAM_BOUNDS["consecutive_votes_required"][0], strong)))
    weak = int(min(PARAM_BOUNDS["consecutive_votes_required_weak"][1], max(strong + 1, weak)))
    params["consecutive_votes_required"] = float(strong)
    params["consecutive_votes_required_weak"] = float(weak)
    for field in FLOAT_FIELDS:
        lo, hi = PARAM_BOUNDS[field]
        params[field] = min(hi, max(lo, params[field]))
    return params


def candidate_key(params: dict[str, float]) -> tuple[Any, ...]:
    return tuple([round(params[field], 8) for field in FLOAT_FIELDS] + [int(params[field]) for field in INT_FIELDS])


def sample_random_params(rng: random.Random) -> dict[str, float]:
    params: dict[str, float] = {}
    for field in FLOAT_FIELDS:
        lo, hi = PARAM_BOUNDS[field]
        if field in {"bias", "score_margin"} or rng.random() < 0.45:
            params[field] = rng.uniform(lo, hi)
        else:
            params[field] = math.exp(rng.uniform(math.log(lo), math.log(hi)))
    strong = rng.randint(1, 5)
    weak = rng.randint(max(2, strong + 1), 8)
    params["consecutive_votes_required"] = float(strong)
    params["consecutive_votes_required_weak"] = float(weak)
    return params


def mutate_params(base: dict[str, float], rng: random.Random) -> dict[str, float]:
    params = dict(base)
    for field in FLOAT_FIELDS:
        lo, hi = PARAM_BOUNDS[field]
        sigma = MUTATION_SIGMA[field] * max(abs(params[field]), 1e-6)
        if field == "bias":
            sigma = 0.22
        params[field] = min(hi, max(lo, params[field] + rng.gauss(0.0, sigma)))
    strong = int(round(params["consecutive_votes_required"] + rng.choice([-1, 0, 1])))
    strong = int(min(5, max(1, strong)))
    weak = int(round(params["consecutive_votes_required_weak"] + rng.choice([-1, 0, 1])))
    weak = int(min(8, max(strong + 1, weak)))
    params["consecutive_votes_required"] = float(strong)
    params["consecutive_votes_required_weak"] = float(weak)
    return params


def generate_candidates(train_rows: list[TrialRow], rng: random.Random, count: int) -> list[dict[str, float]]:
    candidates: list[dict[str, float]] = []
    seen: set[tuple[Any, ...]] = set()

    def add(params: dict[str, float]) -> None:
        normalized = vector_to_params(np.array([params[field] for field in PARAM_FIELDS], dtype=float))
        key = candidate_key(normalized)
        if key not in seen:
            seen.add(key)
            candidates.append(normalized)

    for row in train_rows:
        add(row.params)

    top_rows = sorted(train_rows, key=lambda row: row.normalized_time)[: min(40, len(train_rows))]
    for row in top_rows:
        for _ in range(80):
            add(mutate_params(row.params, rng))

    for benchmark in sorted({row.benchmark for row in train_rows}, key=natural_benchmark_sort):
        bench_rows = [row for row in train_rows if row.benchmark == benchmark]
        best = min(bench_rows, key=lambda row: row.normalized_time)
        for _ in range(120):
            add(mutate_params(best.params, rng))

    top_matrix = np.array([[row.params[field] for field in PARAM_FIELDS] for row in top_rows], dtype=float)
    if len(top_matrix):
        for reducer in [np.mean, np.median, np.min, np.max]:
            add(vector_to_params(reducer(top_matrix, axis=0)))

    while len(candidates) < count:
        add(sample_random_params(rng))
    return candidates[:count]


def select_diverse_topk(
    predictions: np.ndarray,
    candidates: list[dict[str, float]],
    min_scaled_distance: float,
    top_k: int,
) -> list[tuple[int, float, dict[str, float]]]:
    matrix = np.array([[params[field] for field in PARAM_FIELDS] for params in candidates], dtype=float)
    lo = np.array([PARAM_BOUNDS[field][0] for field in PARAM_FIELDS], dtype=float)
    hi = np.array([PARAM_BOUNDS[field][1] for field in PARAM_FIELDS], dtype=float)
    scaled = (matrix - lo) / np.maximum(hi - lo, 1e-9)
    selected: list[tuple[int, float, dict[str, float]]] = []
    for idx in np.argsort(predictions):
        if len(selected) >= top_k:
            break
        if selected:
            dists = [float(np.linalg.norm(scaled[idx] - scaled[prev_idx])) for prev_idx, _, _ in selected]
            if min(dists) < min_scaled_distance:
                continue
        selected.append((int(idx), float(predictions[idx]), candidates[int(idx)]))
    if len(selected) < top_k:
        already = {idx for idx, _, _ in selected}
        for idx in np.argsort(predictions):
            if int(idx) in already:
                continue
            selected.append((int(idx), float(predictions[idx]), candidates[int(idx)]))
            if len(selected) >= top_k:
                break
    return selected


def write_cfg(path: Path, params: dict[str, float], key: str) -> None:
    lines = ["# Auto-generated leave-one-benchmark-out Random Forest cfg", f"key={key}"]
    for field in FLOAT_FIELDS:
        lines.append(f"{field}={params[field]:.8f}")
    for field in INT_FIELDS:
        lines.append(f"{field}={int(round(params[field]))}")
    path.write_text("\n".join(lines) + "\n")


def write_csv(path: Path, rows: list[dict[str, Any]]) -> None:
    if not rows:
        return
    keys: list[str] = []
    for row in rows:
        for key in row:
            if key not in keys:
                keys.append(key)
    with path.open("w", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=keys)
        writer.writeheader()
        for row in rows:
            writer.writerow(row)


def evaluate_heldout(model: RandomForestRegressor, heldout_rows: list[TrialRow]) -> dict[str, Any]:
    x_test, y_test = row_matrix(heldout_rows)
    pred = np.asarray(model.predict(x_test), dtype=float)
    best_actual = float(np.min(y_test))
    selected_i = int(np.argmin(pred))
    selected_actual = float(y_test[selected_i])
    rank_order = np.argsort(y_test)
    selected_rank = int(np.where(rank_order == selected_i)[0][0]) + 1
    return {
        "pred": pred,
        "mae": float(mean_absolute_error(y_test, pred)),
        "rmse": float(math.sqrt(mean_squared_error(y_test, pred))),
        "r2": float(r2_score(y_test, pred)) if len(y_test) > 1 else float("nan"),
        "selected_trial_index": heldout_rows[selected_i].trial_index,
        "selected_predicted_normalized": float(pred[selected_i]),
        "selected_actual_normalized": selected_actual,
        "best_actual_normalized": best_actual,
        "top1_regret": selected_actual - best_actual,
        "selected_actual_rank": selected_rank,
    }


def plot_runtime_distribution(rows: list[TrialRow], benchmarks: list[str], path: Path, run_label: str) -> None:
    fig, ax = plt.subplots(figsize=(11, 5.2))
    data = [[row.normalized_time for row in rows if row.benchmark == benchmark] for benchmark in benchmarks]
    label_keyword = (
        "tick_labels"
        if "tick_labels" in inspect.signature(ax.boxplot).parameters
        else "labels"
    )
    ax.boxplot(data, showmeans=True, **{label_keyword: benchmarks})
    for idx, benchmark in enumerate(benchmarks, start=1):
        ys = [row.normalized_time for row in rows if row.benchmark == benchmark]
        xs = np.full(len(ys), idx) + np.linspace(-0.10, 0.10, len(ys))
        ax.scatter(xs, ys, s=18, alpha=0.65)
    ax.axhline(1.0, color="black", linewidth=1, linestyle="--", alpha=0.55)
    ax.set_title(f"{run_label}: normalized runtime distribution")
    ax.set_ylabel("average_time / benchmark seed_time")
    ax.tick_params(axis="x", rotation=35)
    ax.grid(axis="y", alpha=0.25)
    fig.tight_layout()
    fig.savefig(path, dpi=180)
    plt.close(fig)


def plot_fold_regret(fold_rows: list[dict[str, Any]], path: Path, run_label: str) -> None:
    labels = [row["heldout_benchmark"] for row in fold_rows]
    regrets = [float(row["top1_regret"]) for row in fold_rows]
    ranks = [float(row["selected_actual_rank"]) for row in fold_rows]
    x = np.arange(len(labels))
    fig, axes = plt.subplots(1, 2, figsize=(12, 4.6))
    axes[0].bar(x, regrets, color="#CC6677")
    axes[0].set_xticks(x, labels=labels, rotation=35, ha="right")
    axes[0].set_ylabel("selected actual - heldout best")
    axes[0].set_title("Historical held-out top-1 regret")
    axes[0].grid(axis="y", alpha=0.25)
    axes[1].bar(x, ranks, color="#4477AA")
    axes[1].set_xticks(x, labels=labels, rotation=35, ha="right")
    axes[1].set_ylabel("Actual rank of predicted-best historical cfg")
    axes[1].set_title("Historical selected rank")
    axes[1].grid(axis="y", alpha=0.25)
    fig.suptitle(f"{run_label}: leave-one-benchmark-out Random Forest evaluation")
    fig.tight_layout()
    fig.savefig(path, dpi=180)
    plt.close(fig)


def plot_predicted_vs_actual(prediction_rows: list[dict[str, Any]], path: Path, run_label: str) -> None:
    benchmarks = sorted({row["benchmark"] for row in prediction_rows}, key=natural_benchmark_sort)
    colors = plt.cm.tab10(np.linspace(0, 1, len(benchmarks)))
    color_by = dict(zip(benchmarks, colors))
    fig, ax = plt.subplots(figsize=(7.6, 6.4))
    for benchmark in benchmarks:
        subset = [row for row in prediction_rows if row["benchmark"] == benchmark]
        ax.scatter(
            [float(row["actual_normalized"]) for row in subset],
            [float(row["predicted_normalized"]) for row in subset],
            s=22,
            alpha=0.70,
            color=color_by[benchmark],
            label=benchmark,
        )
    vals = [float(row["actual_normalized"]) for row in prediction_rows] + [float(row["predicted_normalized"]) for row in prediction_rows]
    lo, hi = min(vals) - 0.02, max(vals) + 0.02
    ax.plot([lo, hi], [lo, hi], color="black", linestyle="--", linewidth=1)
    ax.set_xlabel("Actual normalized runtime")
    ax.set_ylabel("Predicted normalized runtime")
    ax.set_title(f"{run_label}: held-out predictions")
    ax.legend(fontsize=8, ncol=2)
    ax.grid(alpha=0.2)
    fig.tight_layout()
    fig.savefig(path, dpi=180)
    plt.close(fig)


def plot_candidate_predictions(candidate_rows: list[dict[str, Any]], path: Path, run_label: str) -> None:
    benchmarks = sorted({row["heldout_benchmark"] for row in candidate_rows}, key=natural_benchmark_sort)
    fig, axes = plt.subplots(2, math.ceil(len(benchmarks) / 2), figsize=(16, 7), sharey=False)
    axes_flat = np.asarray(axes).reshape(-1)
    for ax, benchmark in zip(axes_flat, benchmarks):
        subset = sorted([row for row in candidate_rows if row["heldout_benchmark"] == benchmark], key=lambda row: int(row["rank"]))
        ax.bar([int(row["rank"]) for row in subset], [float(row["predicted_normalized_time"]) for row in subset], color="#228833")
        ax.set_title(benchmark)
        ax.set_xlabel("cfg rank")
        ax.set_ylabel("predicted normalized runtime")
        ax.grid(axis="y", alpha=0.25)
    for ax in axes_flat[len(benchmarks):]:
        ax.axis("off")
    fig.suptitle(f"{run_label}: proposed cfg scores per held-out benchmark")
    fig.tight_layout()
    fig.savefig(path, dpi=180)
    plt.close(fig)


def plot_feature_importance(importance_rows: list[dict[str, Any]], path: Path, run_label: str) -> None:
    benchmarks = sorted({row["heldout_benchmark"] for row in importance_rows}, key=natural_benchmark_sort)
    matrix = np.zeros((len(benchmarks), len(PARAM_FIELDS)))
    for row in importance_rows:
        i = benchmarks.index(row["heldout_benchmark"])
        j = PARAM_FIELDS.index(row["feature"])
        matrix[i, j] = float(row["importance_normalized"])
    fig, ax = plt.subplots(figsize=(13, 5.8))
    image = ax.imshow(matrix, aspect="auto", cmap="YlGnBu")
    ax.set_yticks(np.arange(len(benchmarks)), labels=benchmarks)
    ax.set_xticks(np.arange(len(PARAM_FIELDS)), labels=PARAM_FIELDS, rotation=45, ha="right")
    ax.set_title(f"{run_label}: Random Forest feature importance by held-out fold")
    cbar = fig.colorbar(image, ax=ax)
    cbar.set_label("normalized importance")
    fig.tight_layout()
    fig.savefig(path, dpi=180)
    plt.close(fig)


def plot_candidate_pool_distribution(pool_summary: list[dict[str, Any]], path: Path, run_label: str) -> None:
    benchmarks = [row["heldout_benchmark"] for row in pool_summary]
    mins = [float(row["candidate_pred_min"]) for row in pool_summary]
    p10s = [float(row["candidate_pred_p10"]) for row in pool_summary]
    meds = [float(row["candidate_pred_median"]) for row in pool_summary]
    x = np.arange(len(benchmarks))
    fig, ax = plt.subplots(figsize=(11, 4.8))
    ax.plot(x, mins, marker="o", label="min")
    ax.plot(x, p10s, marker="o", label="p10")
    ax.plot(x, meds, marker="o", label="median")
    ax.set_xticks(x, labels=benchmarks, rotation=35, ha="right")
    ax.set_ylabel("predicted normalized runtime")
    ax.set_title(f"{run_label}: generated candidate pool prediction distribution")
    ax.grid(alpha=0.25)
    ax.legend()
    fig.tight_layout()
    fig.savefig(path, dpi=180)
    plt.close(fig)


def write_summary(
    path: Path,
    run_label: str,
    benchmarks: list[str],
    rows: list[TrialRow],
    fold_rows: list[dict[str, Any]],
    candidate_rows: list[dict[str, Any]],
) -> None:
    mean_regret = float(np.mean([float(row["top1_regret"]) for row in fold_rows]))
    mean_rmse = float(np.mean([float(row["rmse"]) for row in fold_rows]))
    lines = [
        f"# {run_label} Random Forest Leave-One-Benchmark-Out",
        "",
        "## Method",
        "",
        "- Model: RandomForestRegressor only.",
        "- X: cfg parameters only.",
        "- y: average_time / seed_time of the same benchmark.",
        "- Held-out policy: for each benchmark, all rows of that benchmark are excluded from training.",
        "- Leakage-sensitive predictor outputs such as score, voted_mode, mode_after, and switched are not used.",
        "",
        "## Dataset",
        "",
        f"- Benchmarks: {', '.join(benchmarks)}",
        f"- Total trials: {len(rows)}",
        f"- Mean historical held-out RMSE: {mean_rmse:.6f}",
        f"- Mean historical top-1 regret: {mean_regret:.6f}",
        "",
        "## Fold Evaluation",
        "",
        "| held-out | train benchmarks | RMSE | top-1 regret | selected historical rank | proposed cfgs | top-1 cfg |",
        "|---|---|---:|---:|---:|---:|---|",
    ]
    proposal_counts = {}
    for row in candidate_rows:
        proposal_counts[row["heldout_benchmark"]] = proposal_counts.get(row["heldout_benchmark"], 0) + 1
    for row in fold_rows:
        lines.append(
            f"| {row['heldout_benchmark']} | {row['train_benchmarks']} | "
            f"{float(row['rmse']):.6f} | {float(row['top1_regret']):.6f} | "
            f"{row['selected_actual_rank']} | {proposal_counts.get(row['heldout_benchmark'], 0)} | "
            f"`generated_cfg/{row['heldout_benchmark']}/rank_01.cfg` |"
        )
    lines.extend(
        [
            "",
            "## Figure Guide",
            "",
            "- `runtime_distribution.png`: raw trial normalized runtime by benchmark; lower is better.",
            "- `fold_regret_and_rank.png`: leakage-free historical held-out ranking quality.",
            "- `predicted_vs_actual.png`: prediction calibration on held-out historical trial cfgs.",
            "- `candidate_top10_scores.png`: Random Forest predicted score for each proposed cfg rank; rank 1 is the top-1 cfg.",
            "- `candidate_pool_distribution.png`: min/p10/median predicted score in generated candidate pools.",
            "- `feature_importance_heatmap.png`: which cfg parameters the RF used in each held-out fold.",
            "",
            "## Proposed CFGs",
            "",
            "Each held-out benchmark has cfg files under `generated_cfg/<benchmark>/rank_*.cfg`; `rank_01.cfg` is the top-1 proposal.",
        ]
    )
    path.write_text("\n".join(lines) + "\n")


def main() -> int:
    parser = argparse.ArgumentParser()
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument(
        "--ml-root",
        type=Path,
        help="directory containing ml_training/<workload>/history.jsonl",
    )
    source.add_argument(
        "--input-csv",
        type=Path,
        help="portable all_trials_cfg_only-style CSV",
    )
    parser.add_argument("--out-dir", type=Path, required=True)
    parser.add_argument("--candidate-count", type=int, default=6000)
    parser.add_argument(
        "--suite",
        choices=["spec", "gap"],
        required=True,
        help="mandatory suite boundary; SPEC and GAPBS are never mixed",
    )
    parser.add_argument("--top-k", type=int, default=10)
    parser.add_argument("--n-estimators", type=int, default=300)
    parser.add_argument("--n-jobs", type=int, default=4)
    parser.add_argument("--perm-repeats", type=int, default=8)
    parser.add_argument("--random-state", type=int, default=20260606)
    parser.add_argument("--min-scaled-distance", type=float, default=0.18)
    args = parser.parse_args()

    dirs = ensure_dirs(args.out_dir.resolve())
    log_path = dirs["logs"] / "leave_one_benchmark_rf_cfg.log"
    log_path.write_text("")
    if args.ml_root is not None:
        input_source = args.ml_root.resolve()
        run_label = input_source.name
        benchmarks, all_rows = load_trials(input_source, args.suite)
        log(f"ml_root={input_source}", log_path)
    else:
        input_source = args.input_csv.resolve()
        run_label = f"{input_source.parent.name}_{input_source.stem}"
        benchmarks, all_rows = load_trials_csv(input_source, args.suite)
        log(f"input_csv={input_source}", log_path)
    log(f"out_dir={dirs['root']}", log_path)
    if len(benchmarks) < 2:
        raise RuntimeError("Need at least two benchmarks for leave-one-benchmark-out training")
    if not all_rows:
        raise RuntimeError("No usable trial rows were found")
    write_dataset(all_rows, dirs["data"] / "all_trials_cfg_only.csv")
    log(f"suite={args.suite}", log_path)
    log(f"benchmarks={','.join(benchmarks)}", log_path)
    log(f"rows={len(all_rows)}", log_path)

    fold_rows: list[dict[str, Any]] = []
    prediction_rows: list[dict[str, Any]] = []
    candidate_rows: list[dict[str, Any]] = []
    importance_rows: list[dict[str, Any]] = []
    pool_summary: list[dict[str, Any]] = []

    for heldout in benchmarks:
        rng = random.Random(args.random_state + sum(ord(ch) for ch in heldout))
        train_rows = [row for row in all_rows if row.benchmark != heldout]
        heldout_rows = [row for row in all_rows if row.benchmark == heldout]
        train_benchmarks = sorted({row.benchmark for row in train_rows}, key=natural_benchmark_sort)
        x_train, y_train = row_matrix(train_rows)
        model = make_rf(
            args.random_state + len(heldout) * 997 + benchmarks.index(heldout),
            args.n_estimators,
            args.n_jobs,
        )
        model.fit(x_train, y_train)
        dump(model, dirs["models"] / f"rf_without_{heldout}.joblib")

        eval_result = evaluate_heldout(model, heldout_rows)
        fold_row = {
            "heldout_benchmark": heldout,
            "train_benchmarks": " ".join(train_benchmarks),
            "train_rows": len(train_rows),
            "heldout_rows": len(heldout_rows),
            "mae": eval_result["mae"],
            "rmse": eval_result["rmse"],
            "r2": eval_result["r2"],
            "selected_trial_index": eval_result["selected_trial_index"],
            "selected_predicted_normalized": eval_result["selected_predicted_normalized"],
            "selected_actual_normalized": eval_result["selected_actual_normalized"],
            "best_actual_normalized": eval_result["best_actual_normalized"],
            "top1_regret": eval_result["top1_regret"],
            "selected_actual_rank": eval_result["selected_actual_rank"],
        }
        fold_rows.append(fold_row)

        for row, pred in zip(heldout_rows, eval_result["pred"]):
            prediction_rows.append(
                {
                    "heldout_benchmark": heldout,
                    "benchmark": row.benchmark,
                    "trial_index": row.trial_index,
                    "actual_normalized": row.normalized_time,
                    "predicted_normalized": float(pred),
                    "residual": float(pred - row.normalized_time),
                }
            )

        perm = permutation_importance(
            model,
            x_train,
            y_train,
            n_repeats=args.perm_repeats,
            random_state=args.random_state,
            scoring="neg_mean_squared_error",
        )
        values = np.maximum(np.asarray(perm.importances_mean, dtype=float), 0.0)
        total = float(np.sum(values)) or 1.0
        for field, value in zip(PARAM_FIELDS, values):
            importance_rows.append(
                {
                    "heldout_benchmark": heldout,
                    "feature": field,
                    "importance": float(value),
                    "importance_normalized": float(value / total),
                }
            )

        candidates = generate_candidates(train_rows, rng, args.candidate_count)
        candidate_x = np.array([[params[field] for field in PARAM_FIELDS] for params in candidates], dtype=float)
        candidate_pred = np.asarray(model.predict(candidate_x), dtype=float)
        selected = select_diverse_topk(candidate_pred, candidates, args.min_scaled_distance, args.top_k)
        heldout_cfg_dir = dirs["cfg"] / heldout
        heldout_cfg_dir.mkdir(parents=True, exist_ok=True)
        for rank, (candidate_index, predicted, params) in enumerate(selected, start=1):
            cfg_path = heldout_cfg_dir / f"rank_{rank:02d}.cfg"
            write_cfg(cfg_path, params, key=heldout)
            payload: dict[str, Any] = {
                "heldout_benchmark": heldout,
                "rank": rank,
                "candidate_index": candidate_index,
                "predicted_normalized_time": predicted,
                "cfg_path": str(cfg_path),
            }
            payload.update(params)
            candidate_rows.append(payload)
        pool_summary.append(
            {
                "heldout_benchmark": heldout,
                "candidate_count": len(candidates),
                "candidate_pred_min": float(np.min(candidate_pred)),
                "candidate_pred_p10": float(np.percentile(candidate_pred, 10)),
                "candidate_pred_median": float(np.median(candidate_pred)),
                "candidate_pred_max": float(np.max(candidate_pred)),
            }
        )
        log(
            f"heldout={heldout} train_rows={len(train_rows)} rmse={fold_row['rmse']:.6f} "
            f"regret={fold_row['top1_regret']:.6f} cfgs={args.top_k}",
            log_path,
        )

    write_csv(dirs["results"] / "fold_metrics.csv", fold_rows)
    write_csv(dirs["results"] / "heldout_predictions.csv", prediction_rows)
    write_csv(dirs["results"] / "proposed_cfgs.csv", candidate_rows)
    write_csv(dirs["results"] / "feature_importance.csv", importance_rows)
    write_csv(dirs["results"] / "candidate_pool_summary.csv", pool_summary)

    plot_runtime_distribution(all_rows, benchmarks, dirs["figures"] / "runtime_distribution.png", run_label)
    plot_fold_regret(fold_rows, dirs["figures"] / "fold_regret_and_rank.png", run_label)
    plot_predicted_vs_actual(prediction_rows, dirs["figures"] / "predicted_vs_actual.png", run_label)
    plot_candidate_predictions(candidate_rows, dirs["figures"] / "candidate_top10_scores.png", run_label)
    plot_candidate_pool_distribution(pool_summary, dirs["figures"] / "candidate_pool_distribution.png", run_label)
    plot_feature_importance(importance_rows, dirs["figures"] / "feature_importance_heatmap.png", run_label)
    write_summary(dirs["results"] / "summary.md", run_label, benchmarks, all_rows, fold_rows, candidate_rows)
    log("wrote results, cfgs, figures, and summary", log_path)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
