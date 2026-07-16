#!/usr/bin/env python3
"""Validate Figure 11 GAPBS logs and collect normalized performance.

The manifest must contain exactly these columns::

    order,repeat,method,label,log_path

Each manifest method has five rows (``repeat`` 1--5).  Every referenced GAPBS
log must contain exactly ten positive ``Trial Time:`` values.  Trials 6--10
from each repeat are retained, giving 25 samples per manifest method.  The two
adaptive directions (400000/400001 and 400001/400000) are measured separately.
The direction with the lower 25-sample geometric-mean runtime is emitted as the
single final ``adaptive`` result.  Both candidates and all 50 selected adaptive
samples remain in the CSV outputs for auditability.

A final method's normalized performance is ``CXL-only geometric mean / method
geometric mean``.  Values above 1.0 are therefore better than CXL-only.

Relative log paths are resolved from the manifest's directory so that a whole
experiment output directory remains relocatable.
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


REQUIRED_MANIFEST_COLUMNS = ("order", "repeat", "method", "label", "log_path")
ADAPTIVE_METHODS = (
    "adaptive_400000_400001",
    "adaptive_400001_400000",
)
REQUIRED_METHODS = ("cxl", "cache", "cms") + ADAPTIVE_METHODS
OPTIONAL_METHOD = "local"
ALLOWED_METHODS = REQUIRED_METHODS + (OPTIONAL_METHOD,)
EXPECTED_REPEATS = frozenset(range(1, 6))

NUMBER_PATTERN = r"[+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?"
TRIAL_TIME_RE = re.compile(
    rf"^[ \t]*Trial Time:[ \t]+({NUMBER_PATTERN})[ \t]*$"
)

SUMMARY_COLUMNS = (
    "order",
    "method",
    "label",
    "repeat_count",
    "total_trial_count",
    "selected_sample_count",
    "geomean_seconds",
    "cxl_geomean_seconds",
    "normalized_performance",
    "selected_adaptive_direction",
    "adaptive_400000_400001_geomean_seconds",
    "adaptive_400001_400000_geomean_seconds",
    "manifest_path",
)

SAMPLE_COLUMNS = (
    "order",
    "method",
    "label",
    "repeat",
    "selected_index",
    "trial_position",
    "seconds",
    "manifest_log_path",
    "resolved_log_path",
    "selected_for_adaptive_bar",
)


class CollectionError(ValueError):
    """A user-facing manifest, log, or output validation error."""


@dataclass(frozen=True)
class ParsedLog:
    trial_values: Tuple[float, ...]
    selected_values: Tuple[float, ...]


@dataclass(frozen=True)
class ManifestRow:
    line_number: int
    order: int
    repeat: int
    method: str
    label: str
    manifest_log_path: str
    resolved_log_path: Path


@dataclass(frozen=True)
class SelectedSample:
    row: ManifestRow
    selected_index: int
    trial_position: int
    seconds: float


@dataclass(frozen=True)
class MethodResult:
    order: int
    method: str
    label: str
    geomean_seconds: float
    normalized_performance: float
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


def parse_gapbs_log(log_path: Path) -> ParsedLog:
    """Parse exactly ten positive trial times and retain positions 6--10."""

    values: List[float] = []
    for line_number, line in enumerate(_read_log(log_path).splitlines(), start=1):
        match = TRIAL_TIME_RE.fullmatch(line)
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

    return ParsedLog(tuple(values), tuple(values[5:10]))


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
    """Read and fully validate a Figure 11 manifest."""

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
        unexpected = [name for name in headers if name not in REQUIRED_MANIFEST_COLUMNS]
        if unexpected:
            raise CollectionError(
                "manifest has unexpected column(s): " + ", ".join(unexpected)
            )

        rows: List[ManifestRow] = []
        seen_method_repeats = set()
        seen_log_paths: Dict[Path, int] = {}
        method_metadata: Dict[str, Tuple[int, str, int]] = {}
        order_to_method: Dict[int, str] = {}

        for line_number, raw in enumerate(reader, start=2):
            if None in raw:
                raise CollectionError(
                    f"manifest line {line_number}: too many comma-separated fields"
                )
            if all((value or "").strip() == "" for value in raw.values()):
                continue

            values = {key: (value or "").strip() for key, value in raw.items()}
            empty = [name for name in REQUIRED_MANIFEST_COLUMNS if not values[name]]
            if empty:
                raise CollectionError(
                    f"manifest line {line_number}: empty required field(s): "
                    + ", ".join(empty)
                )

            order = _positive_integer(values["order"], "order", line_number)
            repeat = _positive_integer(values["repeat"], "repeat", line_number)
            if repeat not in EXPECTED_REPEATS:
                raise CollectionError(
                    f"manifest line {line_number}: repeat must be in 1..5, got {repeat}"
                )

            method = values["method"].lower()
            if method not in ALLOWED_METHODS:
                raise CollectionError(
                    f"manifest line {line_number}: method must be one of "
                    f"{', '.join(ALLOWED_METHODS)}, got {values['method']!r}"
                )

            pair = (method, repeat)
            if pair in seen_method_repeats:
                raise CollectionError(
                    f"manifest line {line_number}: duplicate repeat {repeat} "
                    f"for method {method!r}"
                )
            seen_method_repeats.add(pair)

            label = values["label"]
            previous_metadata = method_metadata.get(method)
            if previous_metadata is None:
                method_metadata[method] = (order, label, line_number)
            else:
                previous_order, previous_label, previous_line = previous_metadata
                if order != previous_order:
                    raise CollectionError(
                        f"manifest line {line_number}: method {method!r} uses order "
                        f"{order}, but line {previous_line} uses {previous_order}"
                    )
                if label != previous_label:
                    raise CollectionError(
                        f"manifest line {line_number}: method {method!r} uses label "
                        f"{label!r}, but line {previous_line} uses {previous_label!r}"
                    )

            previous_method = order_to_method.get(order)
            if previous_method is not None and previous_method != method:
                raise CollectionError(
                    f"manifest line {line_number}: order {order} is already assigned "
                    f"to method {previous_method!r}"
                )
            order_to_method[order] = method

            manifest_log_path = values["log_path"]
            candidate = Path(manifest_log_path).expanduser()
            if not candidate.is_absolute():
                candidate = manifest_path.parent / candidate
            resolved_log_path = candidate.resolve()
            previous_path_line = seen_log_paths.get(resolved_log_path)
            if previous_path_line is not None:
                raise CollectionError(
                    f"manifest line {line_number}: log path is reused from line "
                    f"{previous_path_line}: {resolved_log_path}"
                )
            seen_log_paths[resolved_log_path] = line_number

            rows.append(
                ManifestRow(
                    line_number=line_number,
                    order=order,
                    repeat=repeat,
                    method=method,
                    label=label,
                    manifest_log_path=manifest_log_path,
                    resolved_log_path=resolved_log_path,
                )
            )

    if not rows:
        raise CollectionError(f"manifest contains no data rows: {manifest_path}")

    methods = set(method_metadata)
    required = set(REQUIRED_METHODS)
    allowed_sets = (required, required | {OPTIONAL_METHOD})
    if methods not in allowed_sets:
        missing = sorted(required - methods)
        unexpected = sorted(methods - (required | {OPTIONAL_METHOD}))
        details = []
        if missing:
            details.append("missing " + ", ".join(missing))
        if unexpected:
            details.append("unexpected " + ", ".join(unexpected))
        raise CollectionError(
            "manifest methods must be cxl, cache, cms, "
            "adaptive_400000_400001, adaptive_400001_400000 with optional "
            "local" + (": " + "; ".join(details) if details else "")
        )

    for method in sorted(methods):
        repeats = {row.repeat for row in rows if row.method == method}
        if repeats != EXPECTED_REPEATS:
            missing = sorted(EXPECTED_REPEATS - repeats)
            extra = sorted(repeats - EXPECTED_REPEATS)
            details = []
            if missing:
                details.append("missing " + ",".join(str(value) for value in missing))
            if extra:
                details.append("extra " + ",".join(str(value) for value in extra))
            raise CollectionError(
                f"method {method!r} must have repeats 1..5: " + "; ".join(details)
            )

    return sorted(rows, key=lambda row: (row.order, row.repeat))


def geometric_mean(values: Sequence[float]) -> float:
    if not values:
        raise CollectionError("cannot compute a geometric mean of zero samples")
    if any(not math.isfinite(value) or value <= 0 for value in values):
        raise CollectionError("geometric-mean samples must be positive and finite")
    return math.exp(math.fsum(math.log(value) for value in values) / len(values))


def _write_summary(
    path: Path,
    results: Sequence[MethodResult],
    cxl_geomean: float,
    manifest_path: Path,
    selected_adaptive_direction: str,
    adaptive_geomeans: Dict[str, float],
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
                        "total_trial_count": 50,
                        "selected_sample_count": len(result.samples),
                        "geomean_seconds": format(result.geomean_seconds, ".12g"),
                        "cxl_geomean_seconds": format(cxl_geomean, ".12g"),
                        "normalized_performance": format(
                            result.normalized_performance, ".12g"
                        ),
                        "selected_adaptive_direction": (
                            selected_adaptive_direction
                            if result.method == "adaptive"
                            else ""
                        ),
                        "adaptive_400000_400001_geomean_seconds": (
                            format(
                                adaptive_geomeans["adaptive_400000_400001"],
                                ".12g",
                            )
                            if result.method == "adaptive"
                            else ""
                        ),
                        "adaptive_400001_400000_geomean_seconds": (
                            format(
                                adaptive_geomeans["adaptive_400001_400000"],
                                ".12g",
                            )
                            if result.method == "adaptive"
                            else ""
                        ),
                        "manifest_path": str(manifest_path),
                    }
                )
    except OSError as exc:
        raise CollectionError(f"cannot write summary CSV {path}: {exc}") from exc


def _write_samples(
    path: Path,
    results: Sequence[MethodResult],
    selected_adaptive_direction: str,
) -> None:
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
                            "selected_index": sample.selected_index,
                            "trial_position": sample.trial_position,
                            "seconds": format(sample.seconds, ".12g"),
                            "manifest_log_path": sample.row.manifest_log_path,
                            "resolved_log_path": str(sample.row.resolved_log_path),
                            "selected_for_adaptive_bar": (
                                "yes"
                                if result.method == selected_adaptive_direction
                                else "no"
                                if result.method in ADAPTIVE_METHODS
                                else ""
                            ),
                        }
                    )
    except OSError as exc:
        raise CollectionError(f"cannot write sample CSV {path}: {exc}") from exc


def collect_results(
    manifest_path: Path, summary_output: Path, samples_output: Path
) -> int:
    """Collect a validated manifest and return the number of methods written."""

    manifest_path = manifest_path.expanduser().resolve()
    summary_output = summary_output.expanduser().resolve()
    samples_output = samples_output.expanduser().resolve()
    if len({manifest_path, summary_output, samples_output}) != 3:
        raise CollectionError(
            "manifest, --summary-output, and --samples-output must be distinct paths"
        )

    manifest_rows = read_manifest(manifest_path)
    grouped_samples: Dict[str, List[SelectedSample]] = {}
    method_metadata: Dict[str, Tuple[int, str]] = {}

    for row in manifest_rows:
        parsed = parse_gapbs_log(row.resolved_log_path)
        method_metadata[row.method] = (row.order, row.label)
        samples = grouped_samples.setdefault(row.method, [])
        for selected_index, seconds in enumerate(parsed.selected_values, start=1):
            samples.append(
                SelectedSample(
                    row=row,
                    selected_index=selected_index,
                    trial_position=selected_index + 5,
                    seconds=seconds,
                )
            )

    for method, samples in grouped_samples.items():
        if len(samples) != 25:
            raise CollectionError(
                f"method {method!r}: expected exactly 25 selected samples, "
                f"found {len(samples)}"
            )

    method_geomeans = {
        method: geometric_mean([sample.seconds for sample in samples])
        for method, samples in grouped_samples.items()
    }
    cxl_geomean = method_geomeans["cxl"]

    manifest_results = []
    for method, (order, label) in method_metadata.items():
        geomean = method_geomeans[method]
        manifest_results.append(
            MethodResult(
                order=order,
                method=method,
                label=label,
                geomean_seconds=geomean,
                normalized_performance=cxl_geomean / geomean,
                samples=tuple(grouped_samples[method]),
            )
        )
    manifest_results.sort(key=lambda result: result.order)

    # Choose on runtime, not rounded normalized performance.  A deterministic
    # tie goes to the forward direction in ADAPTIVE_METHODS order.
    selected_adaptive_direction = min(
        ADAPTIVE_METHODS,
        key=lambda method: (
            method_geomeans[method],
            ADAPTIVE_METHODS.index(method),
        ),
    )
    adaptive_orders = [method_metadata[method][0] for method in ADAPTIVE_METHODS]
    selected_adaptive_geomean = method_geomeans[selected_adaptive_direction]

    # The plot consumes one final Adaptive row.  The direction-level rows are
    # deliberately kept out of this list so Figure 11 remains four bars (or
    # five when Local-only is explicitly included).
    results = [
        result
        for result in manifest_results
        if result.method not in ADAPTIVE_METHODS
    ]
    results.append(
        MethodResult(
            order=min(adaptive_orders),
            method="adaptive",
            label="Adaptive",
            geomean_seconds=selected_adaptive_geomean,
            normalized_performance=cxl_geomean / selected_adaptive_geomean,
            samples=tuple(grouped_samples[selected_adaptive_direction]),
        )
    )
    results.sort(key=lambda result: result.order)

    adaptive_geomeans = {
        method: method_geomeans[method] for method in ADAPTIVE_METHODS
    }
    _write_summary(
        summary_output,
        results,
        cxl_geomean,
        manifest_path,
        selected_adaptive_direction,
        adaptive_geomeans,
    )
    _write_samples(
        samples_output, manifest_results, selected_adaptive_direction
    )
    return len(results)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument(
        "--manifest",
        required=True,
        type=Path,
        help="CSV with order,repeat,method,label,log_path",
    )
    parser.add_argument(
        "--summary-output",
        required=True,
        type=Path,
        help="one-row-per-method output CSV",
    )
    parser.add_argument(
        "--samples-output",
        required=True,
        type=Path,
        help="selected trials 6--10, one sample per output row",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        method_count = collect_results(
            args.manifest, args.summary_output, args.samples_output
        )
    except (CollectionError, OSError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1
    print(f"Collected {method_count} Figure 11 method(s): {args.summary_output}")
    print(f"Wrote selected Figure 11 samples: {args.samples_output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
