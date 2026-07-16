#!/usr/bin/env python3
"""Plot Figure 3 normalized performance bars from collect_results.py output."""

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


POLICY_COLORS = {
    "baseline": "#7F7F7F",
    "anb": "#4E79A7",
    "damon": "#F28E2B",
    "cache": "#59A14F",
    "cms": "#B07AA1",
}
POLICY_NAMES = {
    "baseline": "Baseline",
    "anb": "ANB",
    "damon": "DAMON",
    "cache": "Cache-based",
    "cms": "CMS-based",
}
REQUIRED_COLUMNS = (
    "order",
    "label",
    "policy",
    "threshold",
    "normalized_performance",
)


class PlotError(ValueError):
    """A user-facing CSV or plot configuration error."""


@dataclass(frozen=True)
class PlotRow:
    order: int
    label: str
    policy: str
    threshold: int
    normalized_performance: float


def load_results(results_path: Path) -> List[PlotRow]:
    if not results_path.is_file():
        raise PlotError(f"results CSV does not exist: {results_path}")
    try:
        results_file = results_path.open("r", encoding="utf-8-sig", newline="")
    except OSError as exc:
        raise PlotError(f"cannot open results CSV {results_path}: {exc}") from exc

    with results_file:
        reader = csv.DictReader(results_file)
        headers = reader.fieldnames or []
        missing = [name for name in REQUIRED_COLUMNS if name not in headers]
        if missing:
            raise PlotError(
                "results CSV is missing required column(s): " + ", ".join(missing)
            )

        rows: List[PlotRow] = []
        seen_orders = set()
        for line_number, raw in enumerate(reader, start=2):
            if all((value or "").strip() == "" for value in raw.values()):
                continue
            try:
                order = int((raw["order"] or "").strip())
                threshold = int((raw["threshold"] or "").strip())
                normalized = float((raw["normalized_performance"] or "").strip())
            except (TypeError, ValueError) as exc:
                raise PlotError(
                    f"results line {line_number}: invalid numeric field"
                ) from exc
            if order <= 0 or threshold <= 0:
                raise PlotError(
                    f"results line {line_number}: order and threshold must be positive"
                )
            if order in seen_orders:
                raise PlotError(f"results line {line_number}: duplicate order {order}")
            seen_orders.add(order)
            if not math.isfinite(normalized) or normalized <= 0:
                raise PlotError(
                    f"results line {line_number}: normalized_performance must be "
                    "positive and finite"
                )

            policy = (raw["policy"] or "").strip().lower()
            if policy not in POLICY_COLORS:
                raise PlotError(
                    f"results line {line_number}: unknown policy {policy!r}"
                )
            label = (raw["label"] or "").strip()
            if not label:
                raise PlotError(f"results line {line_number}: label must not be empty")
            rows.append(PlotRow(order, label, policy, threshold, normalized))

    if not rows:
        raise PlotError(f"results CSV contains no data rows: {results_path}")
    baseline_rows = [row for row in rows if row.policy == "baseline"]
    if len(baseline_rows) != 1:
        raise PlotError(
            f"results CSV must contain exactly one baseline row, found {len(baseline_rows)}"
        )
    if not math.isclose(
        baseline_rows[0].normalized_performance, 1.0, rel_tol=1e-6, abs_tol=1e-9
    ):
        raise PlotError("baseline normalized_performance must equal 1.0")
    return sorted(rows, key=lambda row: row.order)


def _axis_label(row: PlotRow) -> str:
    return row.label


def make_plot(
    rows: List[PlotRow], output_prefix: Path, title: Optional[str], dpi: int
) -> Tuple[Path, Path]:
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
    colors = [POLICY_COLORS[row.policy] for row in rows]
    width = max(7.2, 0.72 * len(rows) + 2.2)
    # Reserve dedicated rows above the axes for the figure title and legend.
    # Keeping both as figure-level artists avoids the overlap that occurs when
    # an axes title and an axes legend compete for the same top margin.
    figure, axis = plt.subplots(figsize=(width, 5.0))

    bars = axis.bar(
        x_positions,
        values,
        width=0.72,
        color=colors,
        edgecolor="#333333",
        linewidth=0.65,
        zorder=3,
    )
    axis.axhline(1.0, color="#555555", linewidth=1.0, linestyle="--", zorder=2)
    axis.set_ylabel("Normalized Performance (Baseline = 1.0)", fontsize=11)
    axis.set_xticks(x_positions)
    axis.set_xticklabels([_axis_label(row) for row in rows])
    axis.tick_params(axis="x", labelsize=9)
    axis.tick_params(axis="y", labelsize=9)
    axis.yaxis.set_major_locator(MultipleLocator(0.25))
    axis.yaxis.grid(True, color="#D0D0D0", linewidth=0.7, zorder=0)
    axis.set_axisbelow(True)

    maximum = max(values)
    upper = max(1.25, math.ceil((maximum * 1.17) / 0.25) * 0.25)
    axis.set_ylim(0, upper)
    for bar, value in zip(bars, values):
        axis.text(
            bar.get_x() + bar.get_width() / 2,
            bar.get_height() + upper * 0.018,
            f"{value:.2f}x",
            ha="center",
            va="bottom",
            fontsize=8.5,
        )

    present_policies = []
    for policy in POLICY_COLORS:
        if any(row.policy == policy for row in rows):
            present_policies.append(policy)
    legend_y = 0.89 if title else 0.97
    figure.legend(
        handles=[
            Patch(
                facecolor=POLICY_COLORS[policy],
                edgecolor="#333333",
                label=POLICY_NAMES[policy],
            )
            for policy in present_policies
        ],
        loc="upper center",
        bbox_to_anchor=(0.5, legend_y),
        ncol=len(present_policies),
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
    parser.add_argument("--input", required=True, type=Path, help="collected results CSV")
    parser.add_argument(
        "--output-prefix",
        required=True,
        type=Path,
        help="output path without extension; both PNG and PDF are written",
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
    print(f"Wrote Figure 3 plot: {png_path}")
    print(f"Wrote Figure 3 plot: {pdf_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
