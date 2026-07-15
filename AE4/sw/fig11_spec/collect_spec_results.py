#!/usr/bin/env python3
"""Collect the optional SPEC Figure-11-style normalized-performance result.

The manifest has five complete SPEC invocations per method.  The final
anchored ``; <seconds> total seconds elapsed`` record in each invocation is
selected, giving five runtime samples per method.  Normalized performance is
``CXL-only geomean seconds / method geomean seconds``; values above 1.0 are
therefore better than CXL-only.
"""

from __future__ import annotations

import argparse
import csv
import math
import re
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, List, Sequence, Tuple


# Reuse the rigorously validated Figure 11 manifest format and method set.  The
# SPEC log parser and output schema below remain suite-specific.
FIG11_DIR = Path(__file__).resolve().parents[1] / "fig11"
sys.path.insert(0, str(FIG11_DIR))
from collect_results import (  # noqa: E402
    CollectionError,
    ManifestRow,
    geometric_mean,
    read_manifest,
)


NUMBER_PATTERN = r"[+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?"
TOTAL_SECONDS_RE = re.compile(
    rf";[ \t]*({NUMBER_PATTERN})[ \t]+total seconds[ \t]+elapsed[ \t]*$"
)

SUMMARY_COLUMNS = (
    "order",
    "method",
    "label",
    "repeat_count",
    "total_runtime_match_count",
    "selected_sample_count",
    "geomean_seconds",
    "cxl_geomean_seconds",
    "normalized_performance",
    "manifest_path",
)

SAMPLE_COLUMNS = (
    "order",
    "method",
    "label",
    "repeat",
    "selected_runtime_match_position",
    "seconds",
    "manifest_log_path",
    "resolved_log_path",
)


@dataclass(frozen=True)
class ParsedSpecLog:
    runtime_values: Tuple[float, ...]
    selected_value: float


@dataclass(frozen=True)
class SelectedSample:
    row: ManifestRow
    runtime_match_position: int
    seconds: float


@dataclass(frozen=True)
class MethodResult:
    order: int
    method: str
    label: str
    geomean_seconds: float
    normalized_performance: float
    total_runtime_match_count: int
    samples: Tuple[SelectedSample, ...]


def _read_log(log_path: Path) -> str:
    if not log_path.is_file():
        raise CollectionError(f"log file does not exist: {log_path}")
    try:
        return log_path.read_text(encoding="utf-8", errors="strict")
    except UnicodeDecodeError as exc:
        raise CollectionError(f"log file is not valid UTF-8: {log_path}") from exc
    except OSError as exc:
        raise CollectionError(f"cannot read log file {log_path}: {exc}") from exc


def parse_spec_log(log_path: Path) -> ParsedSpecLog:
    """Validate a completed invocation and select its final runtime record."""

    lines = _read_log(log_path).splitlines()
    if not any(line.strip() == "Run Complete" for line in lines):
        raise CollectionError(f"{log_path}: missing exact 'Run Complete' marker")

    values: List[float] = []
    for line_number, line in enumerate(lines, start=1):
        match = TOTAL_SECONDS_RE.search(line)
        if match is None:
            continue
        value = float(match.group(1))
        if not math.isfinite(value) or value <= 0:
            raise CollectionError(
                f"{log_path}:{line_number}: total seconds must be positive and finite"
            )
        values.append(value)

    if not values:
        raise CollectionError(
            f"{log_path}: no anchored '; <seconds> total seconds elapsed' record"
        )
    return ParsedSpecLog(tuple(values), values[-1])


def _write_summary(
    path: Path,
    results: Sequence[MethodResult],
    cxl_geomean: float,
    manifest_path: Path,
) -> None:
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        with path.open("w", encoding="utf-8", newline="") as output_file:
            writer = csv.DictWriter(output_file, fieldnames=SUMMARY_COLUMNS)
            writer.writeheader()
            for result in results:
                writer.writerow(
                    {
                        "order": result.order,
                        "method": result.method,
                        "label": result.label,
                        "repeat_count": 5,
                        "total_runtime_match_count": result.total_runtime_match_count,
                        "selected_sample_count": len(result.samples),
                        "geomean_seconds": format(result.geomean_seconds, ".12g"),
                        "cxl_geomean_seconds": format(cxl_geomean, ".12g"),
                        "normalized_performance": format(
                            result.normalized_performance, ".12g"
                        ),
                        "manifest_path": str(manifest_path),
                    }
                )
    except OSError as exc:
        raise CollectionError(f"cannot write summary CSV {path}: {exc}") from exc


def _write_samples(path: Path, results: Sequence[MethodResult]) -> None:
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        with path.open("w", encoding="utf-8", newline="") as output_file:
            writer = csv.DictWriter(output_file, fieldnames=SAMPLE_COLUMNS)
            writer.writeheader()
            for result in results:
                for sample in result.samples:
                    writer.writerow(
                        {
                            "order": result.order,
                            "method": result.method,
                            "label": result.label,
                            "repeat": sample.row.repeat,
                            "selected_runtime_match_position": (
                                sample.runtime_match_position
                            ),
                            "seconds": format(sample.seconds, ".12g"),
                            "manifest_log_path": sample.row.manifest_log_path,
                            "resolved_log_path": str(sample.row.resolved_log_path),
                        }
                    )
    except OSError as exc:
        raise CollectionError(f"cannot write sample CSV {path}: {exc}") from exc


def collect_results(
    manifest_path: Path, summary_output: Path, samples_output: Path
) -> int:
    manifest_path = manifest_path.expanduser().resolve()
    summary_output = summary_output.expanduser().resolve()
    samples_output = samples_output.expanduser().resolve()
    if len({manifest_path, summary_output, samples_output}) != 3:
        raise CollectionError(
            "manifest, --summary-output, and --samples-output must be distinct paths"
        )

    rows = read_manifest(manifest_path)
    grouped: Dict[str, List[SelectedSample]] = {}
    method_metadata: Dict[str, Tuple[int, str]] = {}
    total_matches: Dict[str, int] = {}

    for row in rows:
        parsed = parse_spec_log(row.resolved_log_path)
        method_metadata[row.method] = (row.order, row.label)
        total_matches[row.method] = total_matches.get(row.method, 0) + len(
            parsed.runtime_values
        )
        grouped.setdefault(row.method, []).append(
            SelectedSample(
                row=row,
                runtime_match_position=len(parsed.runtime_values),
                seconds=parsed.selected_value,
            )
        )

    for method, samples in grouped.items():
        if len(samples) != 5:
            raise CollectionError(
                f"method {method!r}: expected exactly 5 selected samples, "
                f"found {len(samples)}"
            )

    geomeans = {
        method: geometric_mean([sample.seconds for sample in samples])
        for method, samples in grouped.items()
    }
    cxl_geomean = geomeans["cxl"]
    results = [
        MethodResult(
            order=order,
            method=method,
            label=label,
            geomean_seconds=geomeans[method],
            normalized_performance=cxl_geomean / geomeans[method],
            total_runtime_match_count=total_matches[method],
            samples=tuple(grouped[method]),
        )
        for method, (order, label) in method_metadata.items()
    ]
    results.sort(key=lambda result: result.order)

    _write_summary(summary_output, results, cxl_geomean, manifest_path)
    _write_samples(samples_output, results)
    return len(results)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--manifest",
        required=True,
        type=Path,
        help="CSV with order,repeat,method,label,log_path",
    )
    parser.add_argument(
        "--summary-output", required=True, type=Path, help="one row per method"
    )
    parser.add_argument(
        "--samples-output", required=True, type=Path, help="five selected runtimes"
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        count = collect_results(
            args.manifest, args.summary_output, args.samples_output
        )
    except (CollectionError, OSError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1
    print(f"Collected {count} optional SPEC method(s): {args.summary_output}")
    print(f"Wrote selected SPEC runtime samples: {args.samples_output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
