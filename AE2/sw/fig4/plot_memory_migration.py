#!/usr/bin/env python3
"""Plot memory usage and migration traffic from debug_monitor.log.txt.

By default the axes match the paper-style comparison figure:
  * time: 0--1000 seconds
  * memory: 0--8 GiB
  * migration traffic: 0--800 MB/s

Use --auto-x to end the plot at the final t_sec value in the input log.
"""

from __future__ import annotations

import argparse
import csv
import math
import re
import warnings
from pathlib import Path
from typing import Dict, List

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
from matplotlib.ticker import FuncFormatter, MultipleLocator


REQUIRED_COLUMNS = (
    "t_sec",
    "Total_node0_MB",
    "Total_node1_MB",
    "migration_bandwidth_MBps",
)

LOCAL_COLOR = "#70AD47"
CXL_COLOR = "#ED7D31"
MIGRATION_COLOR = "#2F75B5"
MB_PER_GIB = 1024.0


def parse_args(script_dir: Path) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--input",
        type=Path,
        default=script_dir / "debug_monitor.log.txt",
        help="input CSV (default: debug_monitor.log.txt beside this script)",
    )
    parser.add_argument(
        "--output-prefix",
        type=Path,
        default=script_dir / "memory_usage_migration_traffic",
        help="output path without extension",
    )
    parser.add_argument(
        "--title",
        default=None,
        help="plot title (default: inferred from the threshold directory)",
    )
    parser.add_argument(
        "--x-max",
        type=float,
        default=1000.0,
        help="maximum time in seconds (default: 1000)",
    )
    parser.add_argument(
        "--auto-x",
        action="store_true",
        help="end the X axis at the last t_sec value instead of --x-max",
    )
    parser.add_argument(
        "--memory-max-gib",
        type=float,
        default=8.0,
        help="left-axis maximum in GiB (default: 8)",
    )
    parser.add_argument(
        "--traffic-max-mbps",
        type=float,
        default=800.0,
        help="right-axis maximum in MB/s (default: 800)",
    )
    parser.add_argument("--dpi", type=int, default=300, help="PNG resolution")
    return parser.parse_args()


def infer_title(directory: Path) -> str:
    match = re.match(r"(\d+)_", directory.name)
    if match:
        return f"Threshold {match.group(1)}"
    return "Memory Usage and Migration Traffic"


def load_columns(csv_path: Path) -> Dict[str, List[float]]:
    if not csv_path.is_file():
        raise ValueError(f"input file does not exist: {csv_path}")

    columns: Dict[str, List[float]] = {name: [] for name in REQUIRED_COLUMNS}
    with csv_path.open("r", encoding="utf-8", newline="") as csv_file:
        reader = csv.DictReader(csv_file)
        fieldnames = set(reader.fieldnames or [])
        missing = [name for name in REQUIRED_COLUMNS if name not in fieldnames]
        if missing:
            raise ValueError(f"missing required column(s): {', '.join(missing)}")

        previous_t = -math.inf
        for line_number, row in enumerate(reader, start=2):
            parsed: Dict[str, float] = {}
            for name in REQUIRED_COLUMNS:
                try:
                    value = float(row[name])
                except (TypeError, ValueError) as exc:
                    raise ValueError(
                        f"line {line_number}: {name} is not numeric: {row[name]!r}"
                    ) from exc
                if not math.isfinite(value):
                    raise ValueError(
                        f"line {line_number}: {name} is not finite: {row[name]!r}"
                    )
                parsed[name] = value

            if parsed["t_sec"] <= previous_t:
                raise ValueError(
                    f"line {line_number}: t_sec must be strictly increasing"
                )
            if any(parsed[name] < 0 for name in REQUIRED_COLUMNS[1:]):
                raise ValueError(f"line {line_number}: plotted values must be nonnegative")

            for name in REQUIRED_COLUMNS:
                columns[name].append(parsed[name])
            previous_t = parsed["t_sec"]

    if not columns["t_sec"]:
        raise ValueError(f"input file contains no data rows: {csv_path}")
    return columns


def rounded_upper(observed: float, configured: float, quantum: float) -> float:
    if configured <= 0:
        configured = quantum
    return max(configured, math.ceil(observed / quantum) * quantum)


def make_plot(args: argparse.Namespace, columns: Dict[str, List[float]]) -> None:
    times = columns["t_sec"]
    local_gib = [value / MB_PER_GIB for value in columns["Total_node0_MB"]]
    cxl_gib = [value / MB_PER_GIB for value in columns["Total_node1_MB"]]
    migration_mbps = columns["migration_bandwidth_MBps"]

    x_upper = times[-1] if args.auto_x else max(args.x_max, times[-1])
    memory_upper = rounded_upper(
        max(max(local_gib), max(cxl_gib)), args.memory_max_gib, 1.0
    )
    traffic_upper = rounded_upper(
        max(migration_mbps), args.traffic_max_mbps, 100.0
    )

    fig, memory_axis = plt.subplots(figsize=(6.6, 4.3))
    traffic_axis = memory_axis.twinx()

    local_line, = memory_axis.plot(
        times,
        local_gib,
        color=LOCAL_COLOR,
        linewidth=1.6,
        label="Local Memory",
        zorder=4,
    )
    cxl_line, = memory_axis.plot(
        times,
        cxl_gib,
        color=CXL_COLOR,
        linewidth=1.6,
        label="CXL Memory",
        zorder=4,
    )
    traffic_axis.fill_between(
        times,
        migration_mbps,
        0,
        color=MIGRATION_COLOR,
        alpha=0.28,
        linewidth=0,
        zorder=1,
    )
    traffic_line, = traffic_axis.plot(
        times,
        migration_mbps,
        color=MIGRATION_COLOR,
        linewidth=0.8,
        alpha=0.9,
        label="Migration Traffic",
        zorder=2,
    )

    memory_axis.set_xlim(0, x_upper)
    memory_axis.set_ylim(0, memory_upper)
    traffic_axis.set_ylim(0, traffic_upper)

    memory_axis.set_xlabel("Execution Time (sec)", fontsize=11)
    memory_axis.set_ylabel("Memory Usage", fontsize=11)
    traffic_axis.set_ylabel("Migration Traffic", fontsize=11)

    memory_axis.xaxis.set_major_locator(MultipleLocator(200))
    memory_axis.xaxis.set_minor_locator(MultipleLocator(50))
    memory_axis.yaxis.set_major_locator(MultipleLocator(1))
    memory_axis.yaxis.set_minor_locator(MultipleLocator(0.25))
    traffic_axis.yaxis.set_major_locator(MultipleLocator(100))
    traffic_axis.yaxis.set_minor_locator(MultipleLocator(25))

    memory_axis.yaxis.set_major_formatter(FuncFormatter(lambda value, _: f"{value:g} GiB"))
    traffic_axis.yaxis.set_major_formatter(
        FuncFormatter(lambda value, _: f"{value:g} MB/s")
    )

    memory_axis.grid(which="major", color="#B8B8B8", linewidth=0.7, alpha=0.75)
    memory_axis.grid(which="minor", color="#D8D8D8", linewidth=0.45, alpha=0.65)
    memory_axis.set_axisbelow(True)
    memory_axis.tick_params(axis="both", which="both", direction="out", labelsize=9)
    traffic_axis.tick_params(axis="y", which="both", direction="out", labelsize=9)

    memory_axis.set_title(args.title, fontsize=13, fontweight="bold", pad=12)
    fig.legend(
        handles=(local_line, cxl_line, traffic_line),
        labels=("Local Memory", "CXL Memory", "Migration Traffic"),
        loc="upper center",
        bbox_to_anchor=(0.5, 1.015),
        ncol=3,
        frameon=False,
        fontsize=10,
        handlelength=2.4,
        columnspacing=1.4,
    )

    fig.tight_layout(rect=(0, 0, 1, 0.91))
    args.output_prefix.parent.mkdir(parents=True, exist_ok=True)
    png_path = args.output_prefix.with_suffix(".png")
    pdf_path = args.output_prefix.with_suffix(".pdf")
    fig.savefig(png_path, dpi=args.dpi, bbox_inches="tight")
    fig.savefig(pdf_path, bbox_inches="tight")
    plt.close(fig)

    print(f"Loaded {len(times)} rows from {args.input}")
    print(f"t_sec range: {times[0]:g}..{times[-1]:g}")
    print(f"Local Memory peak: {max(local_gib):.3f} GiB")
    print(f"CXL Memory peak: {max(cxl_gib):.3f} GiB")
    print(f"Migration Traffic peak: {max(migration_mbps):.3f} MB/s")
    print(f"Wrote {png_path}")
    print(f"Wrote {pdf_path}")


def main() -> None:
    script_dir = Path(__file__).resolve().parent
    args = parse_args(script_dir)
    args.input = args.input.expanduser().resolve()
    args.output_prefix = args.output_prefix.expanduser().resolve()
    if args.x_max <= 0 or args.dpi <= 0:
        raise SystemExit("--x-max and --dpi must be positive")
    args.title = args.title or infer_title(args.input.parent)

    try:
        columns = load_columns(args.input)
        make_plot(args, columns)
    except ValueError as exc:
        raise SystemExit(f"ERROR: {exc}") from exc


if __name__ == "__main__":
    main()
