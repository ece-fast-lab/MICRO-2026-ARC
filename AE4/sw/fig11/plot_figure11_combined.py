#!/usr/bin/env python3
"""Plot the three primary GAPBS Figure 11 workloads and their geomean."""

from __future__ import annotations

import argparse
import csv
import math
import sys
import warnings
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, List, Mapping, Optional, Sequence, Tuple

try:
    import matplotlib
except ModuleNotFoundError as exc:  # pragma: no cover - environment dependent
    raise SystemExit("matplotlib is required: python3 -m pip install matplotlib") from exc

matplotlib.use("Agg")

warnings.filterwarnings(
    "ignore",
    message=r"Unable to import Axes3D.*",
    category=UserWarning,
    module=r"matplotlib\.projections",
)

import matplotlib.pyplot as plt
from matplotlib.patches import Patch
from matplotlib.ticker import MultipleLocator


WORKLOAD_ORDER = ("bc_tw", "bfs_tw", "pr_tw")
WORKLOAD_LABELS = {
    "bc_tw": "BC (Twitter)",
    "bfs_tw": "BFS (Twitter)",
    "pr_tw": "PR (Twitter)",
}
METHOD_ORDER = ("cxl", "cache", "cms", "adaptive")
METHOD_ORDERS = {method: index for index, method in enumerate(METHOD_ORDER, start=1)}
METHOD_NAMES = {
    "cxl": "CXL-only",
    "cache": "CHMU-Cache",
    "cms": "CHMU-CMS",
    "adaptive": "Adaptive",
}
METHOD_COLORS = {
    "cxl": "#7F7F7F",
    "cache": "#59A14F",
    "cms": "#B07AA1",
    "adaptive": "#E15759",
}
REQUIRED_COLUMNS = ("order", "method", "label", "normalized_performance")


class PlotError(ValueError):
    """A user-facing combined-plot input or configuration error."""


@dataclass(frozen=True)
class PlotRow:
    """One canonical final-method row exposed for validation and testing."""

    order: int
    method: str
    label: str
    normalized_performance: float


@dataclass(frozen=True)
class WorkloadResult:
    """Validated normalized performance for one primary GAPBS workload."""

    workload: str
    summary_path: Path
    normalized: Mapping[str, float]

    @property
    def rows(self) -> Tuple[PlotRow, ...]:
        """Return the four methods in their strict, canonical CSV order."""

        return tuple(
            PlotRow(
                METHOD_ORDERS[method],
                method,
                METHOD_NAMES[method],
                self.normalized[method],
            )
            for method in METHOD_ORDER
        )


def _parse_input_spec(spec: str) -> Tuple[str, Path]:
    if "=" not in spec:
        raise PlotError(f"--input must be WORKLOAD=PATH, got {spec!r}")
    workload, raw_path = spec.split("=", 1)
    workload = workload.strip()
    raw_path = raw_path.strip()
    if workload not in WORKLOAD_ORDER:
        raise PlotError(
            f"unknown workload {workload!r}; expected " + ", ".join(WORKLOAD_ORDER)
        )
    if not raw_path:
        raise PlotError(f"--input path for {workload} must not be empty")
    return workload, Path(raw_path).expanduser().resolve()


def load_workload_results(workload: str, summary_path: Path) -> WorkloadResult:
    """Read and strictly validate one canonical ``figure11_results.csv``."""

    if workload not in WORKLOAD_ORDER:
        raise PlotError(f"unknown workload {workload!r}")
    summary_path = summary_path.expanduser().resolve()
    if not summary_path.is_file():
        raise PlotError(f"{workload}: summary CSV does not exist: {summary_path}")

    try:
        summary_file = summary_path.open("r", encoding="utf-8-sig", newline="")
    except OSError as exc:
        raise PlotError(f"{workload}: cannot open {summary_path}: {exc}") from exc

    with summary_file:
        reader = csv.DictReader(summary_file)
        headers = reader.fieldnames or []
        if len(headers) != len(set(headers)):
            raise PlotError(f"{workload}: summary CSV has duplicate column names")
        missing = [column for column in REQUIRED_COLUMNS if column not in headers]
        if missing:
            raise PlotError(
                f"{workload}: summary CSV is missing required column(s): "
                + ", ".join(missing)
            )

        by_order: Dict[int, Tuple[str, float]] = {}
        seen_methods = set()
        for line_number, raw in enumerate(reader, start=2):
            if None in raw:
                raise PlotError(
                    f"{workload}: summary line {line_number} has extra field(s)"
                )
            if all((value or "").strip() == "" for value in raw.values()):
                continue
            try:
                order = int((raw.get("order") or "").strip())
                normalized = float(
                    (raw.get("normalized_performance") or "").strip()
                )
            except (TypeError, ValueError) as exc:
                raise PlotError(
                    f"{workload}: summary line {line_number} has an invalid numeric "
                    "order or normalized_performance field"
                ) from exc

            method = (raw.get("method") or "").strip().lower()
            label = (raw.get("label") or "").strip()
            if order in by_order:
                raise PlotError(
                    f"{workload}: summary line {line_number} duplicates order {order}"
                )
            if method in seen_methods:
                raise PlotError(
                    f"{workload}: summary line {line_number} has duplicate method "
                    f"{method!r}; this row duplicates method {method!r}"
                )
            if method not in METHOD_ORDER:
                raise PlotError(
                    f"{workload}: summary line {line_number} has unknown method "
                    f"{method!r}"
                )
            if not label:
                raise PlotError(
                    f"{workload}: summary line {line_number} has an empty label"
                )
            if not math.isfinite(normalized) or normalized <= 0:
                raise PlotError(
                    f"{workload}: summary line {line_number} normalized_performance "
                    "must be positive and finite"
                )
            by_order[order] = (method, normalized)
            seen_methods.add(method)

    expected_orders = list(range(1, len(METHOD_ORDER) + 1))
    if sorted(by_order) != expected_orders:
        raise PlotError(
            f"{workload}: summary must contain exactly orders 1, 2, 3, 4"
        )
    for order, expected_method in enumerate(METHOD_ORDER, start=1):
        actual_method = by_order[order][0]
        if actual_method != expected_method:
            raise PlotError(
                f"{workload}: order {order} must be {expected_method!r}, "
                f"found {actual_method!r}"
            )

    normalized_by_method = {
        method: by_order[METHOD_ORDERS[method]][1] for method in METHOD_ORDER
    }
    if not math.isclose(
        normalized_by_method["cxl"], 1.0, rel_tol=1e-9, abs_tol=1e-9
    ):
        raise PlotError(f"{workload}: CXL-only normalized_performance must equal 1.0")
    return WorkloadResult(workload, summary_path, normalized_by_method)


def load_combined_results(input_specs: Sequence[str]) -> List[WorkloadResult]:
    """Load exactly one summary for each primary GAPBS workload."""

    if len(input_specs) != len(WORKLOAD_ORDER):
        raise PlotError(
            "exactly three --input values are required: bc_tw, bfs_tw, and pr_tw"
        )
    paths: Dict[str, Path] = {}
    for spec in input_specs:
        workload, path = _parse_input_spec(spec)
        if workload in paths:
            raise PlotError(f"duplicate --input workload: {workload}")
        paths[workload] = path
    missing = [workload for workload in WORKLOAD_ORDER if workload not in paths]
    if missing:
        raise PlotError("missing --input workload(s): " + ", ".join(missing))
    return [load_workload_results(workload, paths[workload]) for workload in WORKLOAD_ORDER]


def compute_method_geomeans(results: Sequence[WorkloadResult]) -> Dict[str, float]:
    """Compute the cross-workload geometric mean for every final method."""

    if [result.workload for result in results] != list(WORKLOAD_ORDER):
        raise PlotError("combined results must be in bc_tw, bfs_tw, pr_tw order")
    geomeans: Dict[str, float] = {}
    for method in METHOD_ORDER:
        values = [result.normalized[method] for result in results]
        if any(not math.isfinite(value) or value <= 0 for value in values):
            raise PlotError(f"{method}: geomean inputs must be positive and finite")
        geomeans[method] = math.exp(math.fsum(math.log(value) for value in values) / len(values))
    return geomeans


def make_plot(
    results: Sequence[WorkloadResult],
    output_prefix: Path,
    title: Optional[str],
    dpi: int,
) -> Tuple[Path, Path]:
    """Write grouped PNG and PDF plots and return their paths."""

    geomeans = compute_method_geomeans(results)
    if dpi <= 0:
        raise PlotError("--dpi must be positive")
    if output_prefix.suffix.lower() in (".png", ".pdf"):
        raise PlotError("--output-prefix must not include a .png or .pdf extension")

    output_prefix = output_prefix.expanduser().resolve()
    output_prefix.parent.mkdir(parents=True, exist_ok=True)
    png_path = output_prefix.with_suffix(".png")
    pdf_path = output_prefix.with_suffix(".pdf")

    group_labels = [WORKLOAD_LABELS[result.workload] for result in results] + [
        "GeoMean"
    ]
    group_values = [dict(result.normalized) for result in results] + [geomeans]
    group_centers = list(range(len(group_labels)))
    group_width = 0.78
    bar_width = group_width / len(METHOD_ORDER)

    figure, axis = plt.subplots(figsize=(9.5, 5.4))
    axis.axvspan(2.5, 3.5, color="#F2F2F2", zorder=0)
    axis.axvline(2.5, color="#A0A0A0", linewidth=0.8, linestyle=":", zorder=1)

    all_values: List[float] = []
    method_bars = []
    for method_index, method in enumerate(METHOD_ORDER):
        offset = (method_index - (len(METHOD_ORDER) - 1) / 2) * bar_width
        x_positions = [center + offset for center in group_centers]
        values = [values_by_method[method] for values_by_method in group_values]
        all_values.extend(values)
        bars = axis.bar(
            x_positions,
            values,
            width=bar_width * 0.91,
            color=METHOD_COLORS[method],
            edgecolor="#333333",
            linewidth=0.65,
            zorder=3,
        )
        method_bars.append((bars, values))

    axis.axhline(1.0, color="#555555", linewidth=1.0, linestyle="--", zorder=2)
    axis.set_ylabel("Normalized Performance (CXL-only = 1.0)", fontsize=11)
    axis.set_xticks(group_centers)
    axis.set_xticklabels(group_labels, fontsize=10)
    axis.tick_params(axis="y", labelsize=9)
    axis.yaxis.set_major_locator(MultipleLocator(0.25))
    axis.yaxis.grid(True, color="#D0D0D0", linewidth=0.7, zorder=0)
    axis.set_axisbelow(True)

    maximum = max(all_values)
    upper = max(1.25, math.ceil((maximum * 1.20) / 0.25) * 0.25)
    axis.set_ylim(0, upper)
    for bars, values in method_bars:
        for bar, value in zip(bars, values):
            axis.text(
                bar.get_x() + bar.get_width() / 2,
                bar.get_height() + upper * 0.014,
                f"{value:.2f}x",
                ha="center",
                va="bottom",
                fontsize=7.2,
                rotation=90,
            )

    figure.legend(
        handles=[
            Patch(
                facecolor=METHOD_COLORS[method],
                edgecolor="#333333",
                label=METHOD_NAMES[method],
            )
            for method in METHOD_ORDER
        ],
        loc="upper center",
        bbox_to_anchor=(0.5, 0.90 if title else 0.975),
        ncol=len(METHOD_ORDER),
        frameon=False,
        fontsize=9,
    )
    if title:
        figure.suptitle(title, fontsize=12, fontweight="bold", y=0.978)

    axes_top = 0.84 if title else 0.91
    figure.tight_layout(rect=(0, 0, 1, axes_top))
    try:
        figure.savefig(png_path, dpi=dpi, bbox_inches="tight")
        figure.savefig(pdf_path, bbox_inches="tight")
    except OSError as exc:
        raise PlotError(f"cannot write plot output: {exc}") from exc
    finally:
        plt.close(figure)
    return png_path, pdf_path


def parse_args(argv: Optional[Sequence[str]] = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--input",
        action="append",
        required=True,
        metavar="WORKLOAD=PATH",
        help="repeat once for each of bc_tw, bfs_tw, and pr_tw",
    )
    parser.add_argument(
        "--output-prefix",
        required=True,
        type=Path,
        help="output path without extension; PNG and PDF are both written",
    )
    parser.add_argument("--title", default=None)
    parser.add_argument("--dpi", type=int, default=300)
    return parser.parse_args(argv)


def main(argv: Optional[Sequence[str]] = None) -> int:
    args = parse_args(argv)
    try:
        results = load_combined_results(args.input)
        png_path, pdf_path = make_plot(
            results, args.output_prefix, args.title, args.dpi
        )
    except (PlotError, OSError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1
    print(f"Wrote combined Figure 11 plot: {png_path}")
    print(f"Wrote combined Figure 11 plot: {pdf_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
