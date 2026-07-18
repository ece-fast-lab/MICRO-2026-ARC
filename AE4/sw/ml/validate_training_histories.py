#!/usr/bin/env python3
"""Strictly validate one complete AE4 training suite before LOBO generation."""

from __future__ import annotations

import argparse
import json
import math
from pathlib import Path


MODEL_FIELDS = {
    "key",
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
    "consecutive_votes_required",
    "consecutive_votes_required_weak",
}

SUITES = {
    "gapbs": {
        "bc_twitter": ("bc", "twitter"),
        "bfs_twitter": ("bfs", "twitter"),
        "cc_twitter": ("cc", "twitter"),
        "pr_twitter": ("pr", "twitter"),
        "pr_web": ("pr", "web"),
    },
    "spec": {
        "502": ("502", ""),
        "505": ("505", ""),
        "507": ("507", ""),
        "527": ("527", ""),
        "554": ("554", ""),
    },
}


def fail(message: str) -> None:
    raise ValueError(message)


def load_jsonl(path: Path) -> list[dict]:
    if not path.is_file():
        fail(f"missing history: {path}")
    records = []
    for line_number, raw in enumerate(path.read_text().splitlines(), start=1):
        if not raw.strip():
            continue
        try:
            record = json.loads(raw)
        except json.JSONDecodeError as exc:
            fail(f"{path}:{line_number}: invalid JSON: {exc}")
        if not isinstance(record, dict):
            fail(f"{path}:{line_number}: history row must be a JSON object")
        records.append(record)
    return records


def validate_history(
    history_path: Path,
    suite: str,
    workload_key: str,
    benchmark: str,
    database: str,
    threshold: int,
    target: int,
) -> tuple[str, str]:
    records = load_jsonl(history_path)
    if len(records) != target:
        fail(f"{workload_key}: expected exactly {target} rows, found {len(records)}")

    identity = None
    for expected_index, record in enumerate(records, start=1):
        prefix = f"{workload_key}: row {expected_index}"
        if record.get("trial_index") != expected_index:
            fail(f"{prefix}: trial_index must be {expected_index}")
        if record.get("return_code") != 0:
            fail(f"{prefix}: return_code must be 0")
        if record.get("suite") != suite:
            fail(f"{prefix}: suite must be {suite}")
        if str(record.get("benchmark")) != benchmark:
            fail(f"{prefix}: benchmark must be {benchmark}")
        if str(record.get("db", "")) != database:
            fail(f"{prefix}: db must be {database!r}")
        if int(record.get("th", -1)) != threshold:
            fail(f"{prefix}: threshold must be {threshold}")
        if int(record.get("input_epoch_a", -1)) != 400000 or int(
            record.get("input_epoch_b", -1)
        ) != 400001:
            fail(f"{prefix}: input epoch pair must be 400000/400001")

        swapped = expected_index % 2 == 0
        expected_mode0, expected_mode1 = (
            (400001, 400000) if swapped else (400000, 400001)
        )
        if bool(record.get("order_swapped")) != swapped:
            fail(f"{prefix}: order_swapped does not match the alternating policy")
        if int(record.get("mode0_epoch", -1)) != expected_mode0 or int(
            record.get("mode1_epoch", -1)
        ) != expected_mode1:
            fail(f"{prefix}: mode epoch order does not match the alternating policy")
        if int(record.get("poll_ms", -1)) != 1:
            fail(f"{prefix}: poll_ms must be 1")
        if int(record.get("predictor_interval_ms", -1)) != 10:
            fail(f"{prefix}: predictor_interval_ms must be 10")

        objective = float(record.get("average_time", 0.0))
        if not math.isfinite(objective) or objective <= 0:
            fail(f"{prefix}: average_time must be positive and finite")
        model = record.get("model")
        if not isinstance(model, dict) or not MODEL_FIELDS.issubset(model):
            missing = sorted(MODEL_FIELDS - set(model or {}))
            fail(f"{prefix}: model is missing fields: {', '.join(missing)}")
        if model.get("key") != workload_key:
            fail(f"{prefix}: model key must be {workload_key}")

        host = str(record.get("hostname", ""))
        kernel = str(record.get("kernel_release", ""))
        if not host or not kernel:
            fail(f"{prefix}: hostname/kernel_release provenance is missing")
        if identity is None:
            identity = (host, kernel)
        elif identity != (host, kernel):
            fail(
                f"{prefix}: mixed host/kernel histories are not accepted "
                f"({identity[0]}/{identity[1]} vs {host}/{kernel})"
            )

        for field in ("output_dir", "workload_log", "manager_log"):
            raw_path = str(record.get(field, ""))
            if not raw_path or not Path(raw_path).exists():
                fail(f"{prefix}: recorded {field} is missing: {raw_path or '<empty>'}")

    assert identity is not None
    return identity


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--suite", choices=sorted(SUITES), required=True)
    parser.add_argument("--threshold", type=int, choices=[16, 32, 64, 96], required=True)
    parser.add_argument("--target", type=int, default=20)
    args = parser.parse_args()
    if args.target < 1:
        parser.error("--target must be positive")

    root = args.root.resolve()
    identities = set()
    for workload_key, (benchmark, database) in SUITES[args.suite].items():
        history = root / workload_key / "history.jsonl"
        identities.add(
            validate_history(
                history,
                args.suite,
                workload_key,
                benchmark,
                database,
                args.threshold,
                args.target,
            )
        )
        print(f"OK {workload_key}: {args.target} validated rows")
    if len(identities) != 1:
        fail("suite histories were collected on different host/kernel identities")
    host, kernel = next(iter(identities))
    print(f"OK suite={args.suite} threshold={args.threshold} host={host} kernel={kernel}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
