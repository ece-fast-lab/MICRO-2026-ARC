#!/usr/bin/env python3
"""Plot Figure 11 normalized performance bars from the collected summary CSV."""

from __future__ import annotations

import argparse
import csv
import math
import sys
import warnings
from dataclasses import dataclass
from pathlib import Path
from typing import List, Optional, Tuple

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


REQUIRED_METHODS = ("cxl", "cache", "cms", "adaptive")
OPTIONAL_METHOD = "local"
ALLOWED_METHODS = REQUIRED_METHODS + (OPTIONAL_METHOD,)
REQUIRED_COLUMNS = ("order", "method", "label", "normalized_performance")
METHOD_COLORS = {
    "local": "#4E79A7",
    "cxl": "#7F7F7F",
    "cache": "#59A14F",
    "cms": "#B07AA1",
    "adaptive": "#E15759",
}
METHOD_NAMES = {
    "local": "Local-only",
    "cxl": "CXL-only",
    "cache": "CHMU-Cache",
    "cms": "CHMU-CMS",
    "adaptive": "Adaptive",
}


class PlotError(ValueError):
    """A user-facing summary CSV or plot configuration error."""


@dataclass(frozen=True)
class PlotRow:
    order: int
    method: str
    label: str
    normalized_performance: float


def load_results(summary_path: Path) -> List[PlotRow]:
    if not summary_path.is_file():
        raise PlotError(f"summary CSV does not exist: {summary_path}")
    try:
        summary_file = summary_path.open("r", encoding="utf-8-sig", newline="")
    except OSError as exc:
        raise PlotError(f"cannot open summary CSV {summary_path}: {exc}") from exc

    with summary_file:
        reader = csv.DictReader(summary_file)
        headers = reader.fieldnames or []
        if len(headers) != len(set(headers)):
            raise PlotError(f"summary CSV has duplicate column names: {summary_path}")
        missing = [name for name in REQUIRED_COLUMNS if name not in headers]
        if missing:
            raise PlotError(
                "summary CSV is missing required column(s): " + ", ".join(missing)
            )

        rows: List[PlotRow] = []
        seen_orders = set()
        seen_methods = set()
        for line_number, raw in enumerate(reader, start=2):
            if all((value or "").strip() == "" for value in raw.values()):
                continue
            try:
                order = int((raw.get("order") or "").strip())
                normalized = float(
                    (raw.get("normalized_performance") or "").strip()
                )
            except (TypeError, ValueError) as exc:
                raise PlotError(
                    f"summary line {line_number}: invalid numeric field"
                ) from exc
            if order <= 0:
                raise PlotError(f"summary line {line_number}: order must be positive")
            if order in seen_orders:
                raise PlotError(f"summary line {line_number}: duplicate order {order}")
            seen_orders.add(order)
            if not math.isfinite(normalized) or normalized <= 0:
                raise PlotError(
                    f"summary line {line_number}: normalized_performance must be "
                    "positive and finite"
                )

            method = (raw.get("method") or "").strip().lower()
            if method not in ALLOWED_METHODS:
                raise PlotError(
                    f"summary line {line_number}: unknown method {method!r}"
                )
            if method in seen_methods:
                raise PlotError(
                    f"summary line {line_number}: duplicate method {method!r}"
                )
            seen_methods.add(method)
            label = (raw.get("label") or "").strip()
            if not label:
                raise PlotError(f"summary line {line_number}: label must not be empty")
            rows.append(PlotRow(order, method, label, normalized))

    methods = {row.method for row in rows}
    required = set(REQUIRED_METHODS)
    if methods not in (required, required | {OPTIONAL_METHOD}):
        missing = sorted(required - methods)
        raise PlotError(
            "summary must contain cxl, cache, cms, adaptive with optional local"
            + (": missing " + ", ".join(missing) if missing else "")
        )
    cxl_row = next(row for row in rows if row.method == "cxl")
    if not math.isclose(
        cxl_row.normalized_performance, 1.0, rel_tol=1e-9, abs_tol=1e-9
    ):
        raise PlotError("CXL normalized_performance must equal 1.0")
    return sorted(rows, key=lambda row: row.order)


def make_plot(
    rows: List[PlotRow], output_prefix: Path, title: Optional[str], dpi: int
) -> Tuple[Path, Path]:
    if len(rows) not in (4, 5):
        raise PlotError(f"Figure 11 requires 4 or 5 bars, found {len(rows)}")
    if dpi <= 0:
        raise PlotError("--dpi must be positive")
    if output_prefix.suffix.lower() in (".png", ".pdf"):
        raise PlotError("--output-prefix must not include a .png or .pdf extension")

    output_prefix = output_prefix.expanduser().resolve()
    output_prefix.parent.mkdir(parents=True, exist_ok=True)
    png_path = output_prefix.with_suffix(".png")
    pdf_path = output_prefix.with_suffix(".pdf")

    x_positions = list(range(len(rows)))
    values = [row.normalized_performance for row in rows]
    colors = [METHOD_COLORS[row.method] for row in rows]
    # Give the figure title, method legend, and plotting axes their own
    # vertical regions.  Figure-level artists avoid the title/legend overlap
    # that can occur when both compete for an axes' top margin.
    figure, axis = plt.subplots(figsize=(max(6.8, len(rows) * 1.25), 5.0))
    bars = axis.bar(
        x_positions,
        values,
        width=0.68,
        color=colors,
        edgecolor="#333333",
        linewidth=0.7,
        zorder=3,
    )

    axis.axhline(1.0, color="#555555", linewidth=1.1, linestyle="--", zorder=2)
    axis.set_ylabel("Normalized Performance (CXL-only = 1.0)", fontsize=11)
    axis.set_xticks(x_positions)
    axis.set_xticklabels([row.label for row in rows], fontsize=9)
    axis.tick_params(axis="y", labelsize=9)
    axis.yaxis.set_major_locator(MultipleLocator(0.25))
    axis.yaxis.grid(True, color="#D0D0D0", linewidth=0.7, zorder=0)
    axis.set_axisbelow(True)

    maximum = max(values)
    upper = max(1.25, math.ceil((maximum * 1.18) / 0.25) * 0.25)
    axis.set_ylim(0, upper)
    for bar, value in zip(bars, values):
        axis.text(
            bar.get_x() + bar.get_width() / 2,
            bar.get_height() + upper * 0.018,
            f"{value:.2f}x",
            ha="center",
            va="bottom",
            fontsize=9,
        )

    figure.legend(
        handles=[
            Patch(
                facecolor=METHOD_COLORS[row.method],
                edgecolor="#333333",
                label=METHOD_NAMES[row.method],
            )
            for row in rows
        ],
        loc="upper center",
        bbox_to_anchor=(0.5, 0.89 if title else 0.975),
        ncol=len(rows),
        frameon=False,
        fontsize=9,
    )
    if title:
        figure.suptitle(title, fontsize=12, fontweight="bold", y=0.975)

    axes_top = 0.90 if title else 0.95
    figure.tight_layout(rect=(0, 0, 1, axes_top))
    try:
        figure.savefig(png_path, dpi=dpi, bbox_inches="tight")
        figure.savefig(pdf_path, bbox_inches="tight")
    except OSError as exc:
        raise PlotError(f"cannot write plot output: {exc}") from exc
    finally:
        plt.close(figure)
    return png_path, pdf_path


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--input", required=True, type=Path, help="summary CSV from collect_results.py"
    )
    parser.add_argument(
        "--output-prefix",
        required=True,
        type=Path,
        help="output path without extension; PNG and PDF are both written",
    )
    parser.add_argument("--title", default=None)
    parser.add_argument("--dpi", type=int, default=300)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        rows = load_results(args.input.expanduser().resolve())
        png_path, pdf_path = make_plot(rows, args.output_prefix, args.title, args.dpi)
    except (PlotError, OSError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1
    print(f"Wrote Figure 11 plot: {png_path}")
    print(f"Wrote Figure 11 plot: {pdf_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
