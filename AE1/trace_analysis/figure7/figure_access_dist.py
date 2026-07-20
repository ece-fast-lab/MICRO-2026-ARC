"""
Figure 7 — access-count vs elapsed-time density heatmap (scatter_w100).

x = access_count (log2), y = elapsed time in ms (log). Colored white->blue by
fraction of pages per bin. The x-axis range AND the colorbar normalization are
SHARED across all workloads (so the panels are directly comparable and match the
paper's rendering). Those shared values are FROZEN as _FROZEN_* constants below,
computed once over the full workload set, so this script depends only on the
workloads passed to --render — no other CSVs are needed.

Input CSVs ({workload}_all_{epoch}.csv[.gz]) need only these columns:
  access_count    -- x axis
  active_time_us  -- y axis (elapsed time, W100)
page_addr is carried along for traceability but is not read here; w90_us is not
produced at all (regenerate.sh drops it, since nothing in this figure uses it).

Output (to --out-dir), one per --render workload:
  {workload}_scatter_w100_{epoch}.png

Usage:
    python figure_access_dist.py \\
        --outputs-dir outputs \\
        --epoch 1ms_0ms-1000ms \\
        --render spec_502_gcc_r_c8 gapbs_bc_twitter_t8_n10000000 gapbs_pr_twitter_t8_n10000000 \\
        --out-dir _work
"""

from __future__ import annotations

import argparse
import re
from collections import defaultdict
from pathlib import Path

import matplotlib as mpl
import matplotlib.pyplot as plt
import matplotlib.colors as mcolors
import numpy as np
import pandas as pd

mpl.rcParams["font.family"] = "Arial"
mpl.rcParams["font.size"] = 12

_FIG_W_IN = 10 / 2.54
_FIG_H_IN = 10 / 2.54
_SPAN_COL = "active_time_us"   # W100
_ONE_MS = 1000.0               # microseconds

# --- Frozen shared normalization (bin_count = 20) --------------------------
# The paper renders these panels with an x-axis range and colorbar computed
# over ALL 10 workloads that share this epoch. Those workloads are no longer
# bundled here, so the shared values are frozen below (computed once over the
# full outputs/ set) to keep the panels byte-for-byte identical while depending
# only on the workloads actually saved. Recompute if the underlying data or
# --bin-count changes.
_FROZEN_BINS = 20
_FROZEN_XMIN = 1.0
_FROZEN_XMAX = 61387.0
_FROZEN_VMIN = 4.5188365441926396e-07
_FROZEN_VMAX = 0.8834060098562105


def _even_edges(values: np.ndarray, n: int) -> np.ndarray:
    vmin, vmax = values.min(), values.max()
    bin_size = np.ceil((vmax - vmin) / n)
    return np.linspace(vmin, vmin + bin_size * n, n + 1)


def _log_edges(values: np.ndarray, n: int) -> np.ndarray:
    vmin, vmax = values.min(), values.max()
    return np.logspace(np.log10(max(vmin, 1e-9)), np.log10(vmax), n + 1)


def _y_edges(bs: np.ndarray, y_min_us: float, y_max_us: float, n: int) -> np.ndarray:
    """Log-spaced y-edges with a merged 0~1ms first bin (matches figure_scatter)."""
    y_lo = y_min_us
    y_lo = max(y_lo, bs.min()) if y_lo <= 0 else y_lo
    y_hi = y_max_us if y_max_us is not None else bs.max()
    if y_hi > _ONE_MS and y_lo < _ONE_MS:
        return np.concatenate([[y_lo], np.logspace(np.log10(_ONE_MS), np.log10(y_hi), n)])
    return np.logspace(np.log10(y_lo), np.log10(y_hi), n + 1)


def _render(
    df: pd.DataFrame,
    out_png: Path,
    x_edges: np.ndarray,
    y_min_us: float,
    y_max_us: float,
    bin_count: int,
    norm: mcolors.Normalize,
    out_pdf: Path | None = None,
    out_svg: Path | None = None,
) -> None:
    acc = df["access_count"].to_numpy(dtype=float)
    w = df[_SPAN_COL].to_numpy(dtype=float)
    mask = (acc > 0) & (w > 0)
    acc, bs = acc[mask], w[mask]
    if acc.size < 2:
        print(f"Skipping {out_png.name}: too few valid rows")
        return

    y_edges = _y_edges(bs, y_min_us, y_max_us, bin_count)
    H, xedges, yedges = np.histogram2d(acc, bs, bins=[x_edges, y_edges])
    Z = H.T / acc.size
    Z[Z == 0] = np.nan

    # Make merged 0~1ms first bin the same visual height as the log-spaced bins.
    yedges_display = yedges.copy()
    if len(yedges) > 2:
        log_step = (np.log10(yedges[-1]) - np.log10(yedges[1])) / (len(yedges) - 2)
        yedges_display[0] = yedges[1] / (10 ** log_step)

    fig, ax = plt.subplots(figsize=(_FIG_W_IN, _FIG_H_IN), layout="constrained")
    ax.set_facecolor("white")
    ax.set_box_aspect(1)
    fig.patch.set_facecolor("white")

    cmap = mcolors.LinearSegmentedColormap.from_list(
        "Blues_clipped", plt.cm.Blues(np.linspace(0.15, 1.0, 256))
    )
    cmap.set_bad("white")
    pcm = ax.pcolormesh(xedges, yedges_display, Z, cmap=cmap, norm=norm)

    cax = ax.inset_axes([0, -0.46, 1.0, 0.07])
    cb = fig.colorbar(pcm, cax=cax, orientation="horizontal", label="Fraction of pages")
    cb.ax.xaxis.set_major_locator(mpl.ticker.LogLocator(base=10, numticks=15))
    cb.ax.xaxis.set_minor_locator(mpl.ticker.LogLocator(base=10, subs=np.arange(2, 10), numticks=50))

    # Y axis: log, ticks at 1/10/100/1000 ms (data in µs)
    ax.set_yscale("log")
    ax.set_ylim(yedges_display[0], yedges_display[-1])
    ax.yaxis.set_major_locator(mpl.ticker.FixedLocator([1e3, 1e4, 1e5, 1e6]))
    ax.yaxis.set_minor_locator(mpl.ticker.LogLocator(base=10, subs=np.arange(2, 10), numticks=50))
    ax.yaxis.set_major_formatter(mpl.ticker.FuncFormatter(lambda x, _: f"{x/1e3:.0f}"))

    # X axis: log2, DECIMAL tick labels (1, 4, 16, ..., 16384), rotated.
    ax.set_xscale("log")
    xmax = xedges[-1]
    exp_max = int(np.floor(np.log2(max(xmax, 1))))
    pow2_ticks = [2 ** e for e in range(0, exp_max + 1, 2)]
    ax.set_xticks(pow2_ticks)
    ax.get_xaxis().set_major_formatter(mpl.ticker.FuncFormatter(lambda x, _: f"{int(round(x))}"))
    plt.setp(ax.get_xticklabels(), rotation=45, ha="right", rotation_mode="anchor")

    ax.set_xlabel("Access count", labelpad=4)
    ax.set_ylabel("Elapsed time (ms)")

    out_png.parent.mkdir(parents=True, exist_ok=True)
    plt.savefig(out_png, dpi=150, bbox_inches="tight", facecolor="white")
    if out_pdf is not None:
        plt.savefig(out_pdf, bbox_inches="tight", facecolor="white")
        print(f"Wrote {out_pdf}")
    if out_svg is not None:
        plt.savefig(out_svg, bbox_inches="tight", facecolor="white")
        print(f"Wrote {out_svg}")
    plt.close()
    print(f"Wrote {out_png}")


def _parse_us(s: str) -> float:
    if s.endswith("ms"):
        return float(s[:-2]) * 1000.0
    if s.endswith("us"):
        return float(s[:-2])
    return float(s)


def main() -> None:
    p = argparse.ArgumentParser(description="Figure 7: scatter_w100 with shared x-axis/norm")
    p.add_argument("--outputs-dir", default="outputs")
    p.add_argument("--epoch", default="1ms_0ms-1000ms",
                   help="Epoch label to plot, e.g. 1ms_0ms-1000ms")
    p.add_argument("--render", nargs="+", required=True,
                   help="Workload names to render (norm/axis are frozen constants)")
    p.add_argument("--out-dir", default="_work")
    p.add_argument("--bin-count", type=int, default=20)
    p.add_argument("--pdf", action="store_true", default=False)
    args = p.parse_args()

    outputs_dir = Path(args.outputs_dir)
    out_dir = Path(args.out_dir)
    n = args.bin_count
    render_set = set(args.render)

    if n != _FROZEN_BINS:
        print(f"WARNING: --bin-count {n} != frozen {_FROZEN_BINS}; the frozen "
              f"normalization no longer matches this binning.")

    # Match both plain .csv and gzipped .csv.gz (pandas reads .gz natively, so the
    # bundled traces/*.csv.gz are consumed directly without unpacking).
    pat = re.compile(r"^(.+)_all_(\d+\w+)_(\S+)\.csv$")
    # Only the requested workloads are read; the shared normalization is frozen
    # (see _FROZEN_* above) so no other workloads are needed. The same workload
    # can appear under several subdirs — keep only the canonical <root>/<wl>/ copy.
    entries = []  # (workload, df, y_min_us, y_max_us)
    seen_workloads: set[str] = set()
    for csv_path in sorted(outputs_dir.glob("**/*_all_*.csv*")):
        name = csv_path.name[:-3] if csv_path.name.endswith(".gz") else csv_path.name
        m = pat.match(name)
        if not m:
            continue
        workload, epoch_window, time_range = m.group(1), m.group(2), m.group(3)
        if f"{epoch_window}_{time_range}" != args.epoch:
            continue
        if workload not in render_set:
            continue
        if csv_path.parent != outputs_dir / workload:  # skip nonacc/, epoch/, ... copies
            continue
        if workload in seen_workloads:
            continue
        seen_workloads.add(workload)
        df = pd.read_csv(csv_path)
        if df.empty or _SPAN_COL not in df.columns:
            continue
        try:
            lo, hi = time_range.split("-")
            y_min_us, y_max_us = _parse_us(lo), _parse_us(hi)
        except Exception:
            y_min_us, y_max_us = 0.0, None
        entries.append((workload, df, y_min_us, y_max_us))

    if not entries:
        print(f"No CSVs for epoch {args.epoch} under {outputs_dir}")
        return
    print(f"Found {len(entries)} workload(s) for epoch {args.epoch}")

    # Frozen shared x-edges and colorbar norm (computed once over all workloads).
    shared_x_edges = np.logspace(
        np.log10(max(_FROZEN_XMIN, 1e-9)), np.log10(_FROZEN_XMAX), n + 1)
    shared_norm = mcolors.LogNorm(vmin=_FROZEN_VMIN, vmax=_FROZEN_VMAX)

    # --- Render the requested workloads ---
    saved = 0
    for workload, df, y_min_us, y_max_us in entries:
        stem = f"{workload}_scatter_w100_{args.epoch}"
        _render(
            df,
            out_png=out_dir / f"{stem}.png",
            x_edges=shared_x_edges,
            y_min_us=y_min_us,
            y_max_us=y_max_us,
            bin_count=n,
            norm=shared_norm,
            out_pdf=(out_dir / f"{stem}.pdf") if args.pdf else None,
        )
        saved += 1

    missing = render_set - {w for w, _, _, _ in entries}
    if missing:
        print(f"WARNING: requested workloads not found for this epoch: {sorted(missing)}")
    print(f"Saved {saved} panel(s) to {out_dir}")


if __name__ == "__main__":
    main()
