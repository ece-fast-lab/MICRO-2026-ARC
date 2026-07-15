#!/usr/bin/env python3
"""Run a fresh, resumable CHMU configuration study for one workload.

This is the portable AE4 adaptation of the original repeated-run optimizer.
Only successful, fully validated benchmark runs are appended to history.
``--target-trials`` is a total target, so resuming cannot silently add another
twenty trials.
"""
import argparse
import json
import math
import os
import random
import re
import subprocess
import sys
import time
from pathlib import Path

AVERAGE_TIME_RE = re.compile(r"Average Time:\s*([0-9]+(?:\.[0-9]+)?)")
SPEC_TOTAL_SECONDS_RE = re.compile(r";\s*([0-9]+(?:\.[0-9]+)?)\s+total seconds elapsed")
TRIAL_TIME_RE = re.compile(r"^Trial Time:\s*([0-9]+(?:\.[0-9]+)?)\s*$", re.MULTILINE)

DEFAULT_MODELS = {
    "bc_twitter": {
        "key": "bc_twitter",
        "bw_scale": 2500.0,
        "ipc_scale": 1.35,
        "mpki_scale": 2.60,
        "llc_mpki_scale": 2.10,
        "mem_bound_scale": 32.0,
        "queue_scale": 40.0,
        "dup_rate_scale": 0.14,
        "max_dup_scale": 2.60,
        "dtlb_mpki_scale": 0.90,
        "bias": -0.02,
        "score_margin": 0.16,
        "consecutive_votes_required": 2,
        "consecutive_votes_required_weak": 3,
    },
    "bc_web": {
        "key": "bc_web",
        "bw_scale": 2800.0,
        "ipc_scale": 1.45,
        "mpki_scale": 2.90,
        "llc_mpki_scale": 2.30,
        "mem_bound_scale": 34.0,
        "queue_scale": 44.0,
        "dup_rate_scale": 0.16,
        "max_dup_scale": 2.80,
        "dtlb_mpki_scale": 1.00,
        "bias": -0.05,
        "score_margin": 0.18,
        "consecutive_votes_required": 2,
        "consecutive_votes_required_weak": 3,
    },
    "bc": {
        "key": "bc",
        "bw_scale": 2600.0,
        "ipc_scale": 1.40,
        "mpki_scale": 2.80,
        "llc_mpki_scale": 2.20,
        "mem_bound_scale": 32.0,
        "queue_scale": 48.0,
        "dup_rate_scale": 0.16,
        "max_dup_scale": 2.50,
        "dtlb_mpki_scale": 1.00,
        "bias": -0.05,
        "score_margin": 0.18,
        "consecutive_votes_required": 2,
        "consecutive_votes_required_weak": 3,
    },
    "502": {
        "key": "502",
        "bw_scale": 3200.0,
        "ipc_scale": 1.30,
        "mpki_scale": 3.00,
        "llc_mpki_scale": 2.70,
        "mem_bound_scale": 35.0,
        "queue_scale": 64.0,
        "dup_rate_scale": 0.18,
        "max_dup_scale": 3.00,
        "dtlb_mpki_scale": 1.00,
        "bias": -0.05,
        "score_margin": 0.20,
        "consecutive_votes_required": 2,
        "consecutive_votes_required_weak": 3,
    },
    "505": {
        "key": "505",
        "bw_scale": 1500.0,
        "ipc_scale": 1.70,
        "mpki_scale": 1.50,
        "llc_mpki_scale": 1.20,
        "mem_bound_scale": 25.0,
        "queue_scale": 28.0,
        "dup_rate_scale": 0.10,
        "max_dup_scale": 2.00,
        "dtlb_mpki_scale": 0.80,
        "bias": 0.05,
        "score_margin": 0.15,
        "consecutive_votes_required": 2,
        "consecutive_votes_required_weak": 3,
    },
    "507": {
        "key": "507",
        "bw_scale": 2300.0,
        "ipc_scale": 1.50,
        "mpki_scale": 2.00,
        "llc_mpki_scale": 1.70,
        "mem_bound_scale": 30.0,
        "queue_scale": 36.0,
        "dup_rate_scale": 0.11,
        "max_dup_scale": 2.20,
        "dtlb_mpki_scale": 0.90,
        "bias": 0.05,
        "score_margin": 0.17,
        "consecutive_votes_required": 2,
        "consecutive_votes_required_weak": 3,
    },
    "527": {
        "key": "527",
        "bw_scale": 2100.0,
        "ipc_scale": 1.40,
        "mpki_scale": 1.80,
        "llc_mpki_scale": 1.50,
        "mem_bound_scale": 28.0,
        "queue_scale": 36.0,
        "dup_rate_scale": 0.12,
        "max_dup_scale": 2.20,
        "dtlb_mpki_scale": 0.90,
        "bias": 0.00,
        "score_margin": 0.17,
        "consecutive_votes_required": 2,
        "consecutive_votes_required_weak": 3,
    },
    "554": {
        "key": "554",
        "bw_scale": 1700.0,
        "ipc_scale": 1.60,
        "mpki_scale": 1.30,
        "llc_mpki_scale": 1.00,
        "mem_bound_scale": 24.0,
        "queue_scale": 24.0,
        "dup_rate_scale": 0.10,
        "max_dup_scale": 2.00,
        "dtlb_mpki_scale": 0.80,
        "bias": 0.05,
        "score_margin": 0.15,
        "consecutive_votes_required": 2,
        "consecutive_votes_required_weak": 3,
    },
    "generic": {
        "key": "generic",
        "bw_scale": 2800.0,
        "ipc_scale": 1.40,
        "mpki_scale": 2.50,
        "llc_mpki_scale": 2.00,
        "mem_bound_scale": 30.0,
        "queue_scale": 48.0,
        "dup_rate_scale": 0.14,
        "max_dup_scale": 2.50,
        "dtlb_mpki_scale": 1.00,
        "bias": 0.0,
        "score_margin": 0.20,
        "consecutive_votes_required": 2,
        "consecutive_votes_required_weak": 3,
    },
}

VALID_SPEC_BENCHMARKS = {"502", "505", "507", "527", "554"}

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
    "consecutive_votes_required_weak": (0, 8),
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
    "bias": 0.18,
    "score_margin": 0.18,
}


def load_model_template(model_key: str) -> dict:
    if model_key in DEFAULT_MODELS:
        return dict(DEFAULT_MODELS[model_key])
    base_key = model_key.split("_", 1)[0]
    if base_key in DEFAULT_MODELS:
        model = dict(DEFAULT_MODELS[base_key])
        model["key"] = model_key
        return model
    model = dict(DEFAULT_MODELS["generic"])
    model["key"] = model_key
    return model


def normalize_model_dict(model: dict, fallback_key: str = "generic") -> dict:
    if model is None:
        return load_model_template(fallback_key)

    model_key = model.get("key", fallback_key)
    normalized = load_model_template(model_key)
    for field in ["key", *FLOAT_FIELDS, *INT_FIELDS]:
        if field in model:
            normalized[field] = model[field]

    normalized["consecutive_votes_required"] = max(1, int(normalized["consecutive_votes_required"]))
    normalized["consecutive_votes_required_weak"] = max(
        normalized["consecutive_votes_required"] + 1,
        int(normalized["consecutive_votes_required_weak"]),
    )
    return normalized


def parse_model_file(path: Path, fallback_key: str) -> dict:
    model = load_model_template(fallback_key)
    if not path.exists():
        return model

    for raw_line in path.read_text().splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = [part.strip() for part in line.split("=", 1)]
        if key == "key":
            model["key"] = value
        elif key in INT_FIELDS:
            model[key] = int(value)
        elif key in FLOAT_FIELDS:
            model[key] = float(value)
    return normalize_model_dict(model, fallback_key)


def write_model_file(path: Path, model: dict) -> None:
    model = normalize_model_dict(model)
    path.parent.mkdir(parents=True, exist_ok=True)
    lines = [
        "# Auto-generated CHMU predictor model",
        f"key={model['key']}",
    ]
    for field in FLOAT_FIELDS:
        lines.append(f"{field}={model[field]:.8f}")
    for field in INT_FIELDS:
        lines.append(f"{field}={int(model[field])}")
    path.write_text("\n".join(lines) + "\n")


def vectorize_model(model: dict) -> list:
    normalized = normalize_model_dict(model)
    return [float(normalized[field]) for field in FLOAT_FIELDS] + [float(normalized[field]) for field in INT_FIELDS]


def sample_uniform_model(model_key: str, rng: random.Random) -> dict:
    model = load_model_template(model_key)
    for field in FLOAT_FIELDS:
        lo, hi = PARAM_BOUNDS[field]
        model[field] = rng.uniform(lo, hi)
    for field in INT_FIELDS:
        lo, hi = PARAM_BOUNDS[field]
        model[field] = rng.randint(int(lo), int(hi))
    return normalize_model_dict(model, model_key)


def mutate_model(base_model: dict, rng: random.Random) -> dict:
    base_model = normalize_model_dict(base_model)
    model = dict(base_model)
    for field in FLOAT_FIELDS:
        lo, hi = PARAM_BOUNDS[field]
        sigma = MUTATION_SIGMA[field] * max(abs(base_model[field]), 1e-6)
        mutated = base_model[field] + rng.gauss(0.0, sigma)
        model[field] = min(hi, max(lo, mutated))
    for field in INT_FIELDS:
        lo, hi = PARAM_BOUNDS[field]
        model[field] = max(int(lo), min(int(hi), int(base_model[field] + rng.choice([-1, 0, 1]))))
    return normalize_model_dict(model, base_model.get("key", "generic"))


def maybe_import_sklearn():
    try:
        from sklearn.ensemble import RandomForestRegressor  # type: ignore

        return RandomForestRegressor
    except Exception:
        return None


def propose_candidate(model_key: str,
                      history: list,
                      rng: random.Random,
                      force_rf_surrogate: bool = False) -> tuple:
    if not history:
        if force_rf_surrogate:
            raise RuntimeError(
                "RF surrogate was requested, but no prior training history is available."
            )
        return load_model_template(model_key), "seed"

    best_entry = min(history, key=lambda item: item["average_time"])
    best_model = best_entry["model"]

    rf_cls = maybe_import_sklearn()
    if force_rf_surrogate:
        if rf_cls is None:
            raise RuntimeError(
                "RF surrogate was requested, but scikit-learn is not available in the current Python environment."
            )
        if len(history) < 6:
            raise RuntimeError(
                f"RF surrogate was requested, but at least 6 history samples are required (found {len(history)})."
            )

    if rf_cls is None or len(history) < 6:
        if rng.random() < 0.25:
            return sample_uniform_model(model_key, rng), "global-random"
        return mutate_model(best_model, rng), "local-mutate"

    x_train = [vectorize_model(entry["model"]) for entry in history]
    y_train = [entry["average_time"] for entry in history]
    forest = rf_cls(
        n_estimators=200,
        random_state=rng.randint(0, 1_000_000),
        min_samples_leaf=2,
    )
    forest.fit(x_train, y_train)

    candidates = []
    for _ in range(96):
        candidates.append(mutate_model(best_model, rng))
    for _ in range(32):
        candidates.append(sample_uniform_model(model_key, rng))

    ranked = []
    for candidate in candidates:
        predicted = float(forest.predict([vectorize_model(candidate)])[0])
        ranked.append((predicted, candidate))
    ranked.sort(key=lambda item: item[0])
    return ranked[0][1], "rf-surrogate"


def parse_gapbs_average_time(log_path: Path) -> float:
    text = log_path.read_text(errors="replace")
    matches = AVERAGE_TIME_RE.findall(text)
    if not matches:
        raise RuntimeError(f"Average Time not found in {log_path}")
    return float(matches[-1])


def parse_spec_total_seconds(log_path: Path) -> float:
    text = log_path.read_text(errors="replace")
    matches = SPEC_TOTAL_SECONDS_RE.findall(text)
    if not matches:
        raise RuntimeError(f"SPEC total seconds elapsed not found in {log_path}")
    return float(matches[-1])


def parse_objective_value(log_path: Path, suite: str) -> float:
    if suite == "spec":
        return parse_spec_total_seconds(log_path)
    return parse_gapbs_average_time(log_path)


def build_workload_key(suite: str, benchmark: str, graph_db: str) -> str:
    if suite == "spec":
        return benchmark
    return f"{benchmark}_{graph_db}"


def validate_runtime_summary(run_dir: Path) -> None:
    summary = run_dir / "runtime_summary.txt"
    if not summary.is_file():
        raise RuntimeError(f"Missing runtime summary: {summary}")
    text = summary.read_text(errors="replace")
    required_patterns = [
        r"^WORKLOAD_PID=\S+ rc=0$",
        r"^MIGRATION_MANAGER_PID=\S+ rc=0 failed=0$",
        r"^BACKGROUND_CONTROL_FAILED=0$",
        r"^TRACKER_DISABLE_FAILED=0$",
    ]
    for pattern in required_patterns:
        if re.search(pattern, text, re.MULTILINE) is None:
            raise RuntimeError(f"Runtime summary failed validation ({pattern}): {summary}")


def validate_adaptive_manager_log(manager_log: Path,
                                  model_path: Path,
                                  mode0_epoch: int,
                                  mode1_epoch: int) -> None:
    if not manager_log.is_file():
        raise RuntimeError(f"Missing migration manager log: {manager_log}")
    text = manager_log.read_text(errors="replace")
    loaded = f"[ml-predict] loaded model override from {model_path}"
    active = (
        f"[mode-switch] ML policy active: mode0(epoch={mode0_epoch}) "
        f"vs mode1(epoch={mode1_epoch})"
    )
    if loaded not in text:
        raise RuntimeError(f"Manager did not load the requested cfg {model_path}: {manager_log}")
    if active not in text:
        raise RuntimeError(f"Manager did not activate the requested adaptive policy: {manager_log}")


def run_trial(sw_dir: Path,
              study_dir: Path,
              suite: str,
              benchmark: str,
              graph_db: str,
              th: int,
              mode0_epoch: int,
              mode1_epoch: int,
              poll_ms: int,
              predictor_interval_ms: int,
              model_path: Path,
              copies: int,
              trial_number: int) -> tuple:
    build_option_dir = sw_dir / f"build_option_th{th}"
    if suite == "spec":
        run_script = sw_dir / "benchmark" / "run_spec.sh"
        tag = f"training_{benchmark}_trial{trial_number:04d}"
        run_name = f"{th}_{mode0_epoch}_{mode1_epoch}_{poll_ms}_{benchmark}_mig_{tag}"
        run_argv = [
            "bash", str(run_script), str(th), str(mode0_epoch), str(mode1_epoch),
            str(poll_ms), benchmark, str(copies), "mig", tag,
        ]
    else:
        run_script = sw_dir / "benchmark" / "run_gapbs.sh"
        tag = f"training_{benchmark}_{graph_db}_trial{trial_number:04d}"
        run_name = (
            f"{th}_{mode0_epoch}_{mode1_epoch}_{poll_ms}_{benchmark}_{graph_db}_mig_{tag}"
        )
        run_argv = [
            "bash", str(run_script), str(th), str(mode0_epoch), str(mode1_epoch),
            str(poll_ms), benchmark, graph_db, "mig", tag,
        ]

    if not run_script.is_file():
        raise RuntimeError(f"Missing benchmark runner: {run_script}")
    manager = build_option_dir / "migration_manager"
    if not os.access(manager, os.X_OK):
        raise RuntimeError(f"Migration manager is not built: {manager}")

    output_root = study_dir / "runs"
    output_root.mkdir(parents=True, exist_ok=True)
    output_dir = output_root / run_name
    env = os.environ.copy()
    env["CHMU_MODEL_PATH"] = str(model_path)
    env["CHMU_ALLOW_PREDICTOR_FALLBACK"] = "0"
    env["MIGRATION_PREDICTOR_INTERVAL_MS"] = str(predictor_interval_ms)
    env["CHMU_SPEC_COPIES"] = str(copies)
    env["MIGRATION_MANAGER_DIR"] = str(build_option_dir)
    env["OUT_BASE_DIR"] = str(output_root)
    env["ENABLE_DEBUG_MONITOR"] = "0"
    env["CHMU_ENABLE_FEATURE_TRACE"] = "0"
    env["MIGRATION_MAX_MIGRATED_PFNS"] = "65536"
    env["MIGRATION_CPU"] = "20"
    env["MIGRATION_RECLAIM_DISABLE_AFTER_SEC"] = "1000"
    env["WL_CPUS"] = "0-7"
    env["LOCAL_FREE_LOW_MB"] = "4"
    env["RECLAIM_AMOUNT_MB"] = "2"
    env["RECLAIM_CHECK_SEC"] = "1"
    env["RECLAIM_COOLDOWN_SEC"] = "1"
    env["OMP_THREADS"] = "8"

    start_ts = time.time()
    completed = subprocess.run(
        run_argv,
        cwd=str(study_dir),
        env=env,
        check=False,
    )
    elapsed_wall_sec = time.time() - start_ts
    if completed.returncode != 0:
        raise RuntimeError(
            f"Benchmark trial {trial_number} failed with rc={completed.returncode}; "
            "history was not updated"
        )
    if not output_dir.is_dir():
        raise RuntimeError(f"Runner returned success but output is missing: {output_dir}")

    workload_log = output_dir / (f"{benchmark}.log" if suite == "spec" else f"{benchmark}_{graph_db}.log")
    if not workload_log.is_file():
        raise RuntimeError(f"Missing workload log: {workload_log}")
    if suite == "gapbs":
        trial_times = [float(value) for value in TRIAL_TIME_RE.findall(workload_log.read_text(errors="replace"))]
        if len(trial_times) != 10 or any(value <= 0 for value in trial_times):
            raise RuntimeError(f"Expected exactly ten positive GAPBS Trial Time values: {workload_log}")
    else:
        spec_text = workload_log.read_text(errors="replace")
        if "Run Complete" not in spec_text or len(SPEC_TOTAL_SECONDS_RE.findall(spec_text)) != 1:
            raise RuntimeError(f"Expected one completed SPEC total-seconds result: {workload_log}")
    average_time = parse_objective_value(workload_log, suite)
    if not math.isfinite(average_time) or average_time <= 0:
        raise RuntimeError(f"Objective must be positive and finite: {workload_log}")

    validate_runtime_summary(output_dir)
    manager_log = output_dir / "migration_manager.log"
    validate_adaptive_manager_log(manager_log, model_path, mode0_epoch, mode1_epoch)
    feature_trace = output_dir / "manager_runtime" / "ml_feature_trace.csv"

    return elapsed_wall_sec, output_dir, workload_log, manager_log, feature_trace, average_time


def resolve_epoch_order(base_epoch_a: int, base_epoch_b: int, trial_index: int, auto_swap_order: bool) -> tuple:
    if auto_swap_order and trial_index % 2 == 0:
        return base_epoch_b, base_epoch_a, True
    return base_epoch_a, base_epoch_b, False


def resolve_study_name(benchmark_key: str, epoch_a: int, epoch_b: int) -> tuple:
    normalized_a, normalized_b = sorted((epoch_a, epoch_b))
    pair_suffix = f"{normalized_a}_{normalized_b}"
    if pair_suffix == "400000_400001":
        return benchmark_key, benchmark_key
    return f"{benchmark_key}_{pair_suffix}", f"{benchmark_key}_{pair_suffix}"


def append_history(path: Path, record: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a") as handle:
        handle.write(json.dumps(record, sort_keys=True) + "\n")


def load_history(path: Path) -> list:
    if not path.exists():
        return []
    history = []
    for line in path.read_text().splitlines():
        line = line.strip()
        if not line:
            continue
        history.append(json.loads(line))
    return history


def enrich_history_record(record: dict, epoch_a: int, epoch_b: int, poll_ms: int) -> dict:
    record.setdefault("suite", "gapbs")
    record.setdefault("input_epoch_a", epoch_a)
    record.setdefault("input_epoch_b", epoch_b)
    record.setdefault("mode0_epoch", record.get("input_epoch_a", epoch_a))
    record.setdefault("mode1_epoch", record.get("input_epoch_b", epoch_b))
    record.setdefault("order_swapped", False)
    record.setdefault("poll_ms", poll_ms)
    record.setdefault("copies", 8)
    if "model" in record:
        fallback_key = build_workload_key(record.get("suite", "gapbs"),
                                          record.get("benchmark", "generic"),
                                          record.get("db", ""))
        record["model"] = normalize_model_dict(record["model"], fallback_key)
    return record


def write_best_run_metadata(path: Path, record: dict) -> None:
    payload = {
        "trial_index": record["trial_index"],
        "average_time": record["average_time"],
        "suite": record.get("suite", "gapbs"),
        "benchmark": record["benchmark"],
        "db": record.get("db", ""),
        "copies": record.get("copies", 8),
        "th": record["th"],
        "mode0_epoch": record["mode0_epoch"],
        "mode1_epoch": record["mode1_epoch"],
        "input_epoch_a": record["input_epoch_a"],
        "input_epoch_b": record["input_epoch_b"],
        "order_swapped": record["order_swapped"],
        "poll_ms": record["poll_ms"],
        "predictor_interval_ms": record["predictor_interval_ms"],
        "proposal_kind": record["proposal_kind"],
        "seed_model_path": record.get("seed_model_path", ""),
        "model_path": record["model_path"],
        "output_dir": record["output_dir"],
        "workload_log": record["workload_log"],
        "manager_log": record["manager_log"],
        "feature_trace": record["feature_trace"],
    }
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")


def validate_existing_history(history: list,
                              suite: str,
                              benchmark: str,
                              graph_db: str,
                              th: int) -> None:
    for expected_index, record in enumerate(history, start=1):
        if int(record.get("trial_index", -1)) != expected_index:
            raise RuntimeError(
                f"History trial indices must be contiguous from 1; expected {expected_index}"
            )
        if int(record.get("return_code", 1)) != 0:
            raise RuntimeError(
                f"History contains failed trial {expected_index}; start a fresh study instead"
            )
        if record.get("suite") != suite or record.get("benchmark") != benchmark:
            raise RuntimeError(f"History workload mismatch at trial {expected_index}")
        if suite == "gapbs" and record.get("db") != graph_db:
            raise RuntimeError(f"History graph database mismatch at trial {expected_index}")
        if int(record.get("th", -1)) != th:
            raise RuntimeError(f"History threshold mismatch at trial {expected_index}")
        objective = float(record.get("average_time", 0.0))
        if not math.isfinite(objective) or objective <= 0 or "model" not in record:
            raise RuntimeError(f"History trial {expected_index} has no valid objective/model")


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Portable repeated-run optimizer for one CHMU workload"
    )
    parser.add_argument(
        "--artifact-dir",
        type=Path,
        default=Path(__file__).resolve().parents[2],
        help="AE4 directory (default: inferred from this script)",
    )
    parser.add_argument(
        "--output-root",
        type=Path,
        help="training root (default: AE4/results/training)",
    )
    parser.add_argument("--suite", choices=["gapbs", "spec"], required=True)
    parser.add_argument("--benchmark", required=True)
    parser.add_argument("--db", default="")
    parser.add_argument("--copies", type=int, default=8)
    parser.add_argument("--threshold", type=int, choices=[16, 32, 64, 96], required=True)
    parser.add_argument(
        "--target-trials",
        type=int,
        default=20,
        help="total successful trials desired, including existing history",
    )
    parser.add_argument("--predictor-interval-ms", type=int, default=10)
    parser.add_argument("--epoch-a", type=int, default=400000)
    parser.add_argument("--epoch-b", type=int, default=400001)
    parser.add_argument("--poll-ms", type=int, default=1)
    parser.add_argument(
        "--fixed-order",
        action="store_true",
        help="do not reverse A/B on even trials (not the default AE method)",
    )
    parser.add_argument("--seed-model-path", default="")
    parser.add_argument("--seed", type=int, default=20260319)
    args = parser.parse_args()

    if args.target_trials < 1:
        parser.error("--target-trials must be positive")
    if args.predictor_interval_ms < 1 or args.poll_ms < 1:
        parser.error("predictor and poll intervals must be positive")
    if maybe_import_sklearn() is None:
        parser.error("scikit-learn is required for the 20-trial Random Forest study")
    valid_gap = {
        ("bc", "twitter"),
        ("bfs", "twitter"),
        ("cc", "twitter"),
        ("pr", "twitter"),
        ("pr", "web"),
    }
    if args.suite == "gapbs" and (args.benchmark, args.db) not in valid_gap:
        parser.error(
            "GAPBS workload must be one of: bc_twitter, bfs_twitter, "
            "cc_twitter, pr_twitter, pr_web"
        )
    if args.suite == "spec" and args.benchmark not in VALID_SPEC_BENCHMARKS:
        parser.error(
            "--benchmark for --suite=spec must be one of: "
            + ", ".join(sorted(VALID_SPEC_BENCHMARKS))
        )
    if args.suite == "spec" and args.db:
        parser.error("--db is not used for SPEC")

    artifact_dir = args.artifact_dir.resolve()
    sw_dir = artifact_dir / "sw"
    if not (sw_dir / "benchmark" / "run_gapbs.sh").is_file():
        parser.error(f"not an AE4 artifact directory: {artifact_dir}")
    output_root = (
        args.output_root.resolve()
        if args.output_root is not None
        else artifact_dir / "results" / "training"
    )
    benchmark_key = build_workload_key(args.suite, args.benchmark, args.db)
    study_dir = output_root / f"th{args.threshold}" / args.suite / benchmark_key
    model_dir = study_dir / "models"
    history_path = study_dir / "history.jsonl"
    best_model_path = study_dir / "best.cfg"
    best_run_meta_path = study_dir / "best_run.json"
    study_dir.mkdir(parents=True, exist_ok=True)
    model_dir.mkdir(parents=True, exist_ok=True)

    history = [
        enrich_history_record(entry, args.epoch_a, args.epoch_b, args.poll_ms)
        for entry in load_history(history_path)
    ]
    validate_existing_history(
        history, args.suite, args.benchmark, args.db, args.threshold
    )
    if len(history) > args.target_trials:
        parser.error(
            f"history already has {len(history)} rows, more than target {args.target_trials}; "
            "choose a fresh study directory"
        )
    if best_model_path.exists():
        best_model = parse_model_file(best_model_path, benchmark_key)
    elif history:
        best_record = min(history, key=lambda item: item["average_time"])
        best_model = normalize_model_dict(best_record["model"], benchmark_key)
        write_model_file(best_model_path, best_model)
        write_best_run_metadata(best_run_meta_path, best_record)
    else:
        best_model = load_model_template(benchmark_key)
        write_model_file(best_model_path, best_model)

    seed_model_path = None
    seed_model = None
    if args.seed_model_path:
        seed_model_path = Path(args.seed_model_path).expanduser()
        if not seed_model_path.is_absolute():
            seed_model_path = seed_model_path.resolve()
        if not seed_model_path.exists():
            parser.error(f"--seed-model-path not found: {seed_model_path}")
        seed_model = parse_model_file(seed_model_path, benchmark_key)

    print(
        f"[study] suite={args.suite} benchmark={benchmark_key} "
        f"target_trials={args.target_trials} existing_trials={len(history)}"
    )
    print(f"[study] objective={'total_seconds_elapsed' if args.suite == 'spec' else 'average_time'}")
    print(
        f"[study] epoch_pair={args.epoch_a},{args.epoch_b} poll_ms={args.poll_ms} "
        f"auto_swap_order={not args.fixed_order}"
    )
    if args.suite == "spec":
        print(f"[study] copies={args.copies}")
    print(f"[study] artifact_dir={artifact_dir}")
    print(f"[study] study_dir={study_dir}")
    print(f"[study] best_model_path={best_model_path}")
    print(f"[study] best_run_meta_path={best_run_meta_path}")
    print(f"[study] history_path={history_path}")
    if seed_model_path is not None:
        print(f"[study] seed_model_path={seed_model_path}")

    # Replay proposal calls over existing prefixes to restore the uninterrupted
    # RNG state. This makes --target-trials resume semantics deterministic.
    rng = random.Random(args.seed)
    for existing_count in range(len(history)):
        propose_candidate(benchmark_key, history[:existing_count], rng)

    while len(history) < args.target_trials:
        trial_number = len(history) + 1
        candidate_model, proposal_kind = propose_candidate(
            benchmark_key,
            history,
            rng,
        )
        if trial_number == 1 and seed_model is not None:
            candidate_model = dict(seed_model)
            proposal_kind = "seed-model"
        elif trial_number == 1:
            candidate_model = best_model
            proposal_kind = "seed"
        candidate_model = normalize_model_dict(candidate_model, benchmark_key)

        mode0_epoch, mode1_epoch, order_swapped = resolve_epoch_order(
            args.epoch_a,
            args.epoch_b,
            trial_number,
            not args.fixed_order,
        )

        candidate_path = model_dir / f"trial_{trial_number:04d}.cfg"
        write_model_file(candidate_path, candidate_model)

        print(
            f"[trial {trial_number}] proposal={proposal_kind} model={candidate_path} "
            f"mode0={mode0_epoch} mode1={mode1_epoch} swapped={order_swapped}"
        )
        wall_sec, output_dir, workload_log, manager_log, feature_trace, average_time = run_trial(
            sw_dir,
            study_dir,
            args.suite,
            args.benchmark,
            args.db,
            args.threshold,
            mode0_epoch,
            mode1_epoch,
            args.poll_ms,
            args.predictor_interval_ms,
            candidate_path,
            args.copies,
            trial_number,
        )

        record = {
            "trial_index": trial_number,
            "proposal_kind": proposal_kind,
            "average_time": average_time,
            "return_code": 0,
            "wall_sec": wall_sec,
            "suite": args.suite,
            "predictor_interval_ms": args.predictor_interval_ms,
            "benchmark": args.benchmark,
            "db": args.db,
            "seed_model_path": str(seed_model_path) if seed_model_path is not None else "",
            "copies": args.copies,
            "th": args.threshold,
            "input_epoch_a": args.epoch_a,
            "input_epoch_b": args.epoch_b,
            "mode0_epoch": mode0_epoch,
            "mode1_epoch": mode1_epoch,
            "order_swapped": order_swapped,
            "poll_ms": args.poll_ms,
            "model_path": str(candidate_path),
            "output_dir": str(output_dir),
            "workload_log": str(workload_log),
            "manager_log": str(manager_log),
            "feature_trace": str(feature_trace) if feature_trace.exists() else "",
            "model": candidate_model,
        }
        previous_best = min(
            (entry["average_time"] for entry in history), default=float("inf")
        )
        append_history(history_path, record)
        history.append(record)

        best_record = min(history, key=lambda item: item["average_time"])
        if average_time <= previous_best or math.isclose(average_time, previous_best):
            write_model_file(best_model_path, candidate_model)
            write_best_run_metadata(best_run_meta_path, record)
            best_model = dict(candidate_model)
            print(
                f"[trial {record['trial_index']}] new best average_time={average_time:.5f} "
                f"mode0={mode0_epoch} mode1={mode1_epoch}"
            )
        else:
            print(
                f"[trial {record['trial_index']}] average_time={average_time:.5f} "
                f"best={best_record['average_time']:.5f}"
            )

    final_best = min(history, key=lambda item: item["average_time"])
    write_best_run_metadata(best_run_meta_path, final_best)
    print("")
    print("[study] finished")
    print(f"[study] best average_time={final_best['average_time']:.5f}")
    print(f"[study] best model file={best_model_path}")
    print(
        f"[study] best mode order=mode0:{final_best.get('mode0_epoch', args.epoch_a)} "
        f"mode1:{final_best.get('mode1_epoch', args.epoch_b)} "
        f"swapped={final_best.get('order_swapped', False)}"
    )
    print(f"[study] best run metadata={best_run_meta_path}")
    print(f"[study] best output_dir={final_best['output_dir']}")
    print(f"[study] history saved to={history_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
