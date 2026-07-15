#!/usr/bin/env python3
"""Collect validated Figure 3 runtimes into one normalized CSV file.

Required manifest header:

    order,suite,benchmark,dataset,method,policy,threshold,epoch_a,epoch_b,log_path,label

A relative ``log_path`` is resolved relative to the manifest file, which keeps
the experiment directory relocatable. ``dataset`` may be empty for SPEC.
"""

from __future__ import annotations

import argparse
import csv
import hashlib
import math
import re
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, List, Sequence


REQUIRED_MANIFEST_COLUMNS = (
    "order",
    "suite",
    "benchmark",
    "dataset",
    "method",
    "policy",
    "threshold",
    "epoch_a",
    "epoch_b",
    "log_path",
    "label",
)
POLICIES = ("baseline", "anb", "damon", "cache", "cms")
METHODS = ("baseline", "anb", "damon", "mig")
EXPECTED_METHOD = {
    "baseline": "baseline",
    "anb": "anb",
    "damon": "damon",
    "cache": "mig",
    "cms": "mig",
}

NUMBER_PATTERN = r"(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?"
GAPBS_TRIAL_RE = re.compile(
    rf"^[ \t]*Trial Time:[ \t]+({NUMBER_PATTERN})[ \t]*$"
)
SPEC_SECONDS_RE = re.compile(
    rf"^.*;[ \t]*({NUMBER_PATTERN})[ \t]+total seconds elapsed[ \t]*$"
)
SPEC_COMPLETE_RE = re.compile(r"^[ \t]*Run Complete[ \t]*$")

RESULT_COLUMNS = (
    "order",
    "suite",
    "benchmark",
    "dataset",
    "label",
    "method",
    "policy",
    "threshold",
    "epoch_a",
    "epoch_b",
    "runtime_seconds",
    "baseline_seconds",
    "normalized_performance",
    "normalized_runtime",
    "parser_method",
    "trial_count",
    "selected_trial_count",
    "trial_values_seconds",
    "selected_trial_values_seconds",
    "manifest_log_path",
    "resolved_log_path",
    "log_size_bytes",
    "log_sha256",
    "manifest_path",
)


class CollectionError(ValueError):
    """A user-facing validation error."""


@dataclass(frozen=True)
class ParsedRuntime:
    seconds: float
    parser_method: str
    trial_values: Sequence[float] = ()
    selected_trial_values: Sequence[float] = ()


@dataclass(frozen=True)
class ManifestRow:
    line_number: int
    order: int
    suite: str
    benchmark: str
    dataset: str
    method: str
    policy: str
    threshold: int
    epoch_a: int
    epoch_b: int
    manifest_log_path: str
    resolved_log_path: Path
    label: str


def _read_log(log_path: Path) -> str:
    if not log_path.is_file():
        raise CollectionError(f"log file does not exist: {log_path}")
    try:
        return log_path.read_text(encoding="utf-8", errors="strict")
    except UnicodeDecodeError as exc:
        raise CollectionError(f"log file is not valid UTF-8: {log_path}") from exc
    except OSError as exc:
        raise CollectionError(f"cannot read log file {log_path}: {exc}") from exc


def parse_gapbs_log(log_path: Path) -> ParsedRuntime:
    """Return the geometric mean of GAPBS trials 6--10.

    A Figure 3 GAPBS log is valid only when it contains exactly ten positive
    lines whose complete contents match ``Trial Time: <number>``.
    """

    text = _read_log(log_path)
    values: List[float] = []
    for line_number, line in enumerate(text.splitlines(), start=1):
        match = GAPBS_TRIAL_RE.fullmatch(line)
        if match is None:
            continue
        value = float(match.group(1))
        if not math.isfinite(value) or value <= 0:
            raise CollectionError(
                f"{log_path}:{line_number}: Trial Time must be positive and finite"
            )
        values.append(value)

    if len(values) != 10:
        raise CollectionError(
            f"{log_path}: expected exactly 10 anchored 'Trial Time:' values, "
            f"found {len(values)}"
        )

    selected = values[-5:]
    geometric_mean = math.exp(math.fsum(math.log(value) for value in selected) / 5)
    return ParsedRuntime(
        seconds=geometric_mean,
        parser_method="gapbs_geomean_last_5_of_10",
        trial_values=tuple(values),
        selected_trial_values=tuple(selected),
    )


def parse_spec_log(log_path: Path) -> ParsedRuntime:
    """Return SPEC's single completed-run elapsed time."""

    text = _read_log(log_path)
    lines = text.splitlines()
    if not any(SPEC_COMPLETE_RE.fullmatch(line) for line in lines):
        raise CollectionError(f"{log_path}: missing standalone 'Run Complete' marker")

    matches = []
    for line_number, line in enumerate(lines, start=1):
        match = SPEC_SECONDS_RE.fullmatch(line)
        if match is not None:
            matches.append((line_number, float(match.group(1))))

    if len(matches) != 1:
        raise CollectionError(
            f"{log_path}: expected exactly one '; N total seconds elapsed' marker, "
            f"found {len(matches)}"
        )

    line_number, seconds = matches[0]
    if not math.isfinite(seconds) or seconds <= 0:
        raise CollectionError(
            f"{log_path}:{line_number}: total elapsed seconds must be positive and finite"
        )
    return ParsedRuntime(seconds=seconds, parser_method="spec_total_seconds_elapsed")


def _positive_integer(value: str, field: str, line_number: int) -> int:
    try:
        parsed = int(value)
    except ValueError as exc:
        raise CollectionError(
            f"manifest line {line_number}: {field} must be an integer, got {value!r}"
        ) from exc
    if parsed <= 0:
        raise CollectionError(
            f"manifest line {line_number}: {field} must be positive, got {parsed}"
        )
    return parsed


def read_manifest(manifest_path: Path) -> List[ManifestRow]:
    if not manifest_path.is_file():
        raise CollectionError(f"manifest file does not exist: {manifest_path}")

    try:
        manifest_file = manifest_path.open("r", encoding="utf-8-sig", newline="")
    except OSError as exc:
        raise CollectionError(f"cannot open manifest {manifest_path}: {exc}") from exc

    with manifest_file:
        reader = csv.DictReader(manifest_file)
        headers = reader.fieldnames or []
        if len(headers) != len(set(headers)):
            raise CollectionError(f"manifest has duplicate column names: {manifest_path}")
        missing = [name for name in REQUIRED_MANIFEST_COLUMNS if name not in headers]
        if missing:
            raise CollectionError(
                "manifest is missing required column(s): " + ", ".join(missing)
            )
        allowed = set(REQUIRED_MANIFEST_COLUMNS)
        unexpected = [name for name in headers if name not in allowed]
        if unexpected:
            raise CollectionError(
                "manifest has unexpected column(s): " + ", ".join(unexpected)
            )

        rows: List[ManifestRow] = []
        seen_orders = set()
        for line_number, raw in enumerate(reader, start=2):
            if None in raw:
                raise CollectionError(
                    f"manifest line {line_number}: too many comma-separated fields"
                )
            if all((value or "").strip() == "" for value in raw.values()):
                continue

            values: Dict[str, str] = {
                key: (value or "").strip() for key, value in raw.items()
            }
            empty = [
                name
                for name in REQUIRED_MANIFEST_COLUMNS
                if name != "dataset" and not values[name]
            ]
            if empty:
                raise CollectionError(
                    f"manifest line {line_number}: empty required field(s): "
                    + ", ".join(empty)
                )

            order = _positive_integer(values["order"], "order", line_number)
            if order in seen_orders:
                raise CollectionError(
                    f"manifest line {line_number}: duplicate order value {order}"
                )
            seen_orders.add(order)

            policy = values["policy"].lower()
            if policy not in POLICIES:
                raise CollectionError(
                    f"manifest line {line_number}: policy must be one of "
                    f"{', '.join(POLICIES)}, got {values['policy']!r}"
                )

            suite = values["suite"].lower()
            if suite not in ("gapbs", "spec"):
                raise CollectionError(
                    f"manifest line {line_number}: suite must be gapbs or spec, "
                    f"got {values['suite']!r}"
                )
            if suite == "gapbs" and not values["dataset"]:
                raise CollectionError(
                    f"manifest line {line_number}: GAPBS dataset must not be empty"
                )
            method = values["method"].lower()
            if method not in METHODS:
                raise CollectionError(
                    f"manifest line {line_number}: method must be one of "
                    f"{', '.join(METHODS)}, got {values['method']!r}"
                )
            if method != EXPECTED_METHOD[policy]:
                raise CollectionError(
                    f"manifest line {line_number}: policy {policy!r} requires "
                    f"method {EXPECTED_METHOD[policy]!r}, got {method!r}"
                )

            manifest_log_path = values["log_path"]
            candidate = Path(manifest_log_path).expanduser()
            if not candidate.is_absolute():
                candidate = manifest_path.parent / candidate
            resolved_log_path = candidate.resolve()

            rows.append(
                ManifestRow(
                    line_number=line_number,
                    order=order,
                    suite=suite,
                    benchmark=values["benchmark"],
                    dataset=values["dataset"],
                    method=method,
                    policy=policy,
                    threshold=_positive_integer(
                        values["threshold"], "threshold", line_number
                    ),
                    epoch_a=_positive_integer(values["epoch_a"], "epoch_a", line_number),
                    epoch_b=_positive_integer(values["epoch_b"], "epoch_b", line_number),
                    manifest_log_path=manifest_log_path,
                    resolved_log_path=resolved_log_path,
                    label=values["label"],
                )
            )

    if not rows:
        raise CollectionError(f"manifest contains no data rows: {manifest_path}")
    baseline_count = sum(row.policy == "baseline" for row in rows)
    if baseline_count != 1:
        raise CollectionError(
            f"manifest must contain exactly one baseline row, found {baseline_count}"
        )
    return sorted(rows, key=lambda row: row.order)


def _number_list(values: Sequence[float]) -> str:
    return "|".join(format(value, ".12g") for value in values)


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    try:
        with path.open("rb") as log_file:
            while True:
                chunk = log_file.read(1024 * 1024)
                if not chunk:
                    break
                digest.update(chunk)
    except OSError as exc:
        raise CollectionError(f"cannot hash log file {path}: {exc}") from exc
    return digest.hexdigest()


def collect_results(suite: str, manifest_path: Path, output_path: Path) -> int:
    suite = suite.lower()
    if suite not in ("gapbs", "spec"):
        raise CollectionError(f"suite must be gapbs or spec, got {suite!r}")

    manifest_path = manifest_path.expanduser().resolve()
    output_path = output_path.expanduser().resolve()
    if manifest_path == output_path:
        raise CollectionError("output CSV must not overwrite the input manifest")

    manifest_rows = read_manifest(manifest_path)
    mismatched_suites = [row for row in manifest_rows if row.suite != suite]
    if mismatched_suites:
        row = mismatched_suites[0]
        raise CollectionError(
            f"manifest line {row.line_number}: suite {row.suite!r} does not match "
            f"--suite {suite!r}"
        )
    parser = parse_gapbs_log if suite == "gapbs" else parse_spec_log
    parsed_rows = []
    for row in manifest_rows:
        parsed = parser(row.resolved_log_path)
        stat = row.resolved_log_path.stat()
        parsed_rows.append((row, parsed, stat.st_size, _sha256(row.resolved_log_path)))

    baseline_seconds = next(
        parsed.seconds
        for row, parsed, _size, _digest in parsed_rows
        if row.policy == "baseline"
    )

    output_path.parent.mkdir(parents=True, exist_ok=True)
    try:
        with output_path.open("w", encoding="utf-8", newline="") as output_file:
            writer = csv.DictWriter(output_file, fieldnames=RESULT_COLUMNS)
            writer.writeheader()
            for row, parsed, log_size, log_sha256 in parsed_rows:
                writer.writerow(
                    {
                        "order": row.order,
                        "suite": row.suite,
                        "benchmark": row.benchmark,
                        "dataset": row.dataset,
                        "label": row.label,
                        "method": row.method,
                        "policy": row.policy,
                        "threshold": row.threshold,
                        "epoch_a": row.epoch_a,
                        "epoch_b": row.epoch_b,
                        "runtime_seconds": format(parsed.seconds, ".12g"),
                        "baseline_seconds": format(baseline_seconds, ".12g"),
                        "normalized_performance": format(
                            baseline_seconds / parsed.seconds, ".12g"
                        ),
                        "normalized_runtime": format(
                            parsed.seconds / baseline_seconds, ".12g"
                        ),
                        "parser_method": parsed.parser_method,
                        "trial_count": len(parsed.trial_values),
                        "selected_trial_count": len(parsed.selected_trial_values),
                        "trial_values_seconds": _number_list(parsed.trial_values),
                        "selected_trial_values_seconds": _number_list(
                            parsed.selected_trial_values
                        ),
                        "manifest_log_path": row.manifest_log_path,
                        "resolved_log_path": str(row.resolved_log_path),
                        "log_size_bytes": log_size,
                        "log_sha256": log_sha256,
                        "manifest_path": str(manifest_path),
                    }
                )
    except OSError as exc:
        raise CollectionError(f"cannot write results CSV {output_path}: {exc}") from exc
    return len(parsed_rows)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=(
            "Required manifest columns:\n"
            "  order,suite,benchmark,dataset,method,policy,threshold,epoch_a,"
            "epoch_b,log_path,label\n\n"
            "Allowed method values: baseline, anb, damon, mig\n"
            "Allowed policy values: baseline, anb, damon, cache, cms"
        ),
    )
    parser.add_argument("--suite", required=True, choices=("gapbs", "spec"))
    parser.add_argument("--manifest", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        row_count = collect_results(args.suite, args.manifest, args.output)
    except (CollectionError, OSError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1
    print(f"Collected {row_count} validated {args.suite} result(s): {args.output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
