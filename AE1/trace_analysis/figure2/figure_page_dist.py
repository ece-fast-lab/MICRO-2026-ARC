"""
Figure 2 — per-page hotness distribution (access_count vs burstiness).

Trimmed from figure_th_cum.py: generates ONLY the three panels used in Figure 2,
so no byproduct PNGs are produced:
  {workload}_cum_all_1ms_{start}ms-{end}ms.png          -- all pages (fig2a)
  {workload}_cum_single_lfu_ao_th{T}_1ms_{...}.png       -- LFU always-on hot pages (fig2b)
  {workload}_cum_single_cms_ee_th{T}_1ms_{...}.png       -- CMS epoch-end hot pages (fig2c)

Hot pages come from nonacc hotlists (epoch-level detection) and are displayed on
the cumulative scatter space (access_count vs W100 access rate). The two single
panels share one color scale (vmax) so they are directly comparable.

Usage:
    python figure_page_dist.py \\
        --outputs-dir outputs/gapbs_pr_twitter_t8_n10000000 \\
        --nonacc-dir  outputs/nonacc/gapbs_pr_twitter_t8_n10000000 \\
        --workload    gapbs_pr_twitter_t8_n10000000 \\
        --start-ms 10 --end-ms 11 \\
        --single-th 32 --max-hot 256 --x-max 128 \\
        --out-dir .
"""

from __future__ import annotations

import argparse
from pathlib import Path

import matplotlib as mpl
import matplotlib.pyplot as plt
import matplotlib.colors as mcolors
import numpy as np
import pandas as pd

mpl.rcParams["font.family"] = "Arial"
mpl.rcParams["font.size"] = 12

_FIG_W_IN = 20 / 2.54


def _resolve_csv(path: Path) -> Path | None:
    """Return `path`, or its .gz sibling if only that exists (pandas reads .gz
    natively, so the bundled traces/*.csv.gz are consumed without unpacking)."""
    if path.exists():
        return path
    gz = path.with_name(path.name + ".gz")
    return gz if gz.exists() else None


def _access_rate(acc: np.ndarray, w: np.ndarray) -> np.ndarray:
    with np.errstate(divide="ignore", invalid="ignore"):
        return np.where(w > 0, acc / w * 1e6, np.nan)


def _log_edges(values: np.ndarray, n: int) -> np.ndarray:
    vmin, vmax = values.min(), values.max()
    return np.logspace(np.log10(max(vmin, 1e-9)), np.log10(vmax), n + 1)


def _even_edges(values: np.ndarray, n: int) -> np.ndarray:
    vmin, vmax = values.min(), values.max()
    bin_size = np.ceil((vmax - vmin) / n)
    return np.linspace(vmin, vmin + bin_size * n, n + 1)


def _setup_ax(ax: plt.Axes, x_edges: np.ndarray, y_edges: np.ndarray, xlabel: bool = True) -> None:
    ax.set_facecolor("white")
    ax.set_yscale("log")
    ax.set_box_aspect(1)
    ax.yaxis.set_minor_locator(mpl.ticker.LogLocator(base=10, subs=np.arange(2, 10), numticks=100))
    ax.tick_params(axis="y", which="minor", left=True)
    xmax = x_edges[-1]
    step = int(np.ceil(xmax / 5 / 16)) * 16
    step = max(step, 16)
    ax.set_xticks(np.arange(0, xmax + step, step))
    ax.set_xlim(x_edges[0], x_edges[-1])
    ax.set_ylim(y_edges[0], y_edges[-1])
    if xlabel:
        ax.set_xlabel("Access count")


def _save(fig: plt.Figure, out_png: Path, out_pdf: Path | None) -> None:
    out_png.parent.mkdir(parents=True, exist_ok=True)
    fig.savefig(out_png, dpi=150, bbox_inches="tight", facecolor="white")
    print(f"Wrote {out_png}")
    if out_pdf is not None:
        out_pdf.parent.mkdir(parents=True, exist_ok=True)
        fig.savefig(out_pdf, bbox_inches="tight", facecolor="white")
        print(f"Wrote {out_pdf}")
    plt.close(fig)


def _make_cmap() -> mcolors.LinearSegmentedColormap:
    cmap = mcolors.LinearSegmentedColormap.from_list(
        "Blues_clipped", plt.cm.Blues(np.linspace(0.15, 1.0, 256))
    )
    cmap.set_bad("white")
    return cmap


# ---------------------------------------------------------------------------
# fig2a: all pages
# ---------------------------------------------------------------------------

def figure_cum_all(
    all_df: pd.DataFrame,
    out_png: Path,
    span_col: str = "active_span_us",
    bin_count: int = 20,
    out_pdf: Path | None = None,
    x_max: int | None = None,
) -> None:
    """Single-subplot scatter of all cumulative pages."""
    acc = all_df["access_count"].to_numpy(dtype=float)
    w = all_df[span_col].to_numpy(dtype=float)
    bs = _access_rate(acc, w)
    mask = (acc > 0) & (w > 0) & np.isfinite(bs)
    acc, bs = acc[mask], bs[mask]

    if acc.size < 2:
        print(f"Skipping {out_png.name}: too few valid rows")
        return

    x_edges = np.linspace(0, x_max, bin_count + 1) if x_max is not None else _even_edges(acc, bin_count)
    y_edges = _log_edges(bs, bin_count)
    H, xedges, yedges = np.histogram2d(acc, bs, bins=[x_edges, y_edges])
    Z = H.T / acc.size
    Z[Z == 0] = np.nan

    subplot_w = _FIG_W_IN / 3
    fig_h = subplot_w + 1.0
    fig, ax = plt.subplots(figsize=(subplot_w, fig_h), layout="constrained")
    fig.patch.set_facecolor("white")

    cmap = _make_cmap()
    norm = mcolors.LogNorm(vmin=np.nanmin(Z), vmax=np.nanmax(Z))
    pcm = ax.pcolormesh(xedges, yedges, Z, cmap=cmap, norm=norm)

    _setup_ax(ax, xedges, yedges)
    ax.set_ylabel("Burstiness (accesses/s)")

    cax = ax.inset_axes([0, -0.37, 1.0, 0.07])
    cb = fig.colorbar(pcm, cax=cax, orientation="horizontal", label="Fraction of pages")
    cb.ax.xaxis.set_major_locator(mpl.ticker.LogLocator(base=10, numticks=15))
    cb.ax.xaxis.set_minor_locator(mpl.ticker.LogLocator(base=10, subs=np.arange(2, 10), numticks=50))

    _save(fig, out_png, out_pdf)


# ---------------------------------------------------------------------------
# fig2b / fig2c: single-threshold hot pages (per algorithm)
# ---------------------------------------------------------------------------

def figure_cum_single_thr(
    all_df: pd.DataFrame,
    hot_df: pd.DataFrame,
    out_png: Path,
    span_col: str = "active_span_us",
    bin_count: int = 20,
    out_pdf: Path | None = None,
    x_max: int | None = None,
    max_hot: int | None = None,
    shared_vmax: float | None = None,
) -> None:
    """Single-subplot scatter of hot pages at a given threshold."""
    acc_all = all_df["access_count"].to_numpy(dtype=float)
    w_all = all_df[span_col].to_numpy(dtype=float)
    bs_all = _access_rate(acc_all, w_all)
    base_mask = (acc_all > 0) & (w_all > 0) & np.isfinite(bs_all)

    if base_mask.sum() < 2:
        print(f"Skipping {out_png.name}: insufficient base data")
        return

    x_edges = np.linspace(0, x_max, bin_count + 1) if x_max is not None else _even_edges(acc_all[base_mask], bin_count)
    y_edges = _log_edges(bs_all[base_mask], bin_count)

    m = hot_df[["page_addr", "epoch_idx"]].merge(
        all_df[["page_addr", "epoch_idx", "access_count", span_col]],
        on=["page_addr", "epoch_idx"], how="inner"
    )
    if m.empty:
        print(f"Skipping {out_png.name}: no matching hot pages")
        return

    acc = m["access_count"].to_numpy(dtype=float)
    w = m[span_col].to_numpy(dtype=float)
    bs = _access_rate(acc, w)
    mask = (acc > 0) & (w > 0) & np.isfinite(bs)
    acc, bs = acc[mask], bs[mask]

    if acc.size < 2:
        print(f"Skipping {out_png.name}: too few valid rows")
        return

    n_epochs = all_df["epoch_idx"].nunique()
    denom = max_hot * n_epochs if (max_hot is not None and n_epochs > 0) else acc.size

    H, xedges, yedges = np.histogram2d(acc, bs, bins=[x_edges, y_edges])
    Z = H.T / denom
    Z[Z == 0] = np.nan

    subplot_w = _FIG_W_IN / 3
    fig_h = subplot_w + 1.0
    fig, ax = plt.subplots(figsize=(subplot_w, fig_h), layout="constrained")
    fig.patch.set_facecolor("white")

    cmap = _make_cmap()
    vmax = shared_vmax if shared_vmax is not None else np.nanmax(Z)
    norm = mcolors.Normalize(vmin=0, vmax=vmax)
    pcm = ax.pcolormesh(xedges, yedges, Z, cmap=cmap, norm=norm)

    _setup_ax(ax, xedges, yedges)
    ax.set_ylabel("Burstiness (accesses/s)")

    cax = ax.inset_axes([0, -0.37, 1.0, 0.07])
    fig.colorbar(pcm, cax=cax, orientation="horizontal", label="Hot page ratio")

    _save(fig, out_png, out_pdf)


# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------

def main() -> None:
    parser = argparse.ArgumentParser(
        description="Figure 2: per-page hotness distribution (all pages + per-algo hot pages)"
    )
    parser.add_argument("--outputs-dir", required=True,
                        help="Dir with {workload}_all_1ms_0ms-{N}ms.csv")
    parser.add_argument("--nonacc-dir", required=True,
                        help="Dir with *_nonacc_hotlist_*.csv")
    parser.add_argument("--workload", required=True)
    parser.add_argument("--end-ms", type=int, nargs="+", default=[11])
    parser.add_argument("--start-ms", type=int, nargs="+", default=None,
                        help="Start time(s) in ms (paired with --end-ms; default: 0 for all)")
    parser.add_argument("--single-th", type=int, nargs="+", default=[32],
                        help="Threshold(s) for the per-algo hot-page panels")
    parser.add_argument("--max-hot", type=int, default=None,
                        help="Max hot pages per epoch used in hotlist CSVs (e.g. 256)")
    parser.add_argument("--bin-count", type=int, default=20)
    parser.add_argument("--x-max", type=int, default=None,
                        help="Fix x-axis max (access count); e.g. 128")
    parser.add_argument("--out-dir", default=".")
    parser.add_argument("--pdf", action="store_true", default=False,
                        help="Also save PDF")
    args = parser.parse_args()

    nonacc_dir = Path(args.nonacc_dir)
    out_dir = Path(args.out_dir)
    span_col = "active_span_us"
    maxhot_tag = f"_maxhot{args.max_hot}" if args.max_hot is not None else ""

    if args.start_ms is not None:
        if len(args.start_ms) != len(args.end_ms):
            raise ValueError("--start-ms and --end-ms must have the same number of values")
        time_ranges = list(zip(args.start_ms, args.end_ms))
    else:
        time_ranges = [(0, e) for e in args.end_ms]

    for start_ms, end_ms in time_ranges:
        range_tag = f"{start_ms}ms-{end_ms}ms"
        nonacc_all_path = _resolve_csv(
            nonacc_dir / f"{args.workload}_nonacc_all_1ms_{range_tag}.csv")
        if nonacc_all_path is None:
            print(f"Missing: {nonacc_dir}/{args.workload}_nonacc_all_1ms_{range_tag}.csv[.gz]")
            continue
        nonacc_df = pd.read_csv(nonacc_all_path)
        if nonacc_df.empty:
            print(f"Empty: {nonacc_all_path.name}")
            continue
        all_df = nonacc_df.copy()
        print(f"\n[{range_tag}] {len(all_df)} (page, epoch) pairs from {nonacc_all_path.name}")

        suffix = f"1ms_{range_tag}"
        pdf_fn = lambda s: out_dir / f"{s}.pdf" if args.pdf else None

        # --- fig2a: all pages ---
        stem_all = f"{args.workload}_cum_all_{suffix}"
        figure_cum_all(
            all_df,
            out_png=out_dir / f"{stem_all}.png",
            span_col=span_col,
            bin_count=args.bin_count,
            out_pdf=pdf_fn(stem_all),
            x_max=args.x_max,
        )

        # --- fig2b / fig2c: per-algo hot pages, one shared color scale ---
        for sth in args.single_th:
            single_hot: dict[str, pd.DataFrame] = {}
            for algo_key in ("lfu_ao", "cms_ee"):
                stem = f"{args.workload}_nonacc_hotlist_{algo_key}_th{sth}{maxhot_tag}_{suffix}.csv"
                hot_path = _resolve_csv(nonacc_dir / stem)
                if hot_path is not None:
                    single_hot[algo_key] = pd.read_csv(hot_path)
                else:
                    print(f"  Missing single-th hotlist: {stem}[.gz]")

            # Pass 1: shared vmax across algos
            acc_all = all_df["access_count"].to_numpy(dtype=float)
            w_all = all_df[span_col].to_numpy(dtype=float)
            bs_all = _access_rate(acc_all, w_all)
            base_mask = (acc_all > 0) & (w_all > 0) & np.isfinite(bs_all)
            x_edges = np.linspace(0, args.x_max, args.bin_count + 1) if args.x_max is not None else _even_edges(acc_all[base_mask], args.bin_count)
            y_edges = _log_edges(bs_all[base_mask], args.bin_count)
            n_epochs = all_df["epoch_idx"].nunique()
            denom = args.max_hot * n_epochs if (args.max_hot is not None and n_epochs > 0) else None

            single_vmax = 0.0
            for hot_df in single_hot.values():
                m = hot_df[["page_addr", "epoch_idx"]].merge(
                    all_df[["page_addr", "epoch_idx", "access_count", span_col]],
                    on=["page_addr", "epoch_idx"], how="inner"
                )
                if m.empty:
                    continue
                acc = m["access_count"].to_numpy(dtype=float)
                w = m[span_col].to_numpy(dtype=float)
                bs = _access_rate(acc, w)
                mask = (acc > 0) & (w > 0) & np.isfinite(bs)
                H, _, _ = np.histogram2d(acc[mask], bs[mask], bins=[x_edges, y_edges])
                Z = H.T / (denom if denom is not None else mask.sum())
                Z[Z == 0] = np.nan
                v = np.nanmax(Z)
                if np.isfinite(v) and v > single_vmax:
                    single_vmax = v

            # Pass 2: render each algo with the shared vmax
            for algo_key, hot_df in single_hot.items():
                stem_sth = f"{args.workload}_cum_single_{algo_key}_th{sth}_{suffix}"
                figure_cum_single_thr(
                    all_df,
                    hot_df=hot_df,
                    out_png=out_dir / f"{stem_sth}.png",
                    span_col=span_col,
                    bin_count=args.bin_count,
                    out_pdf=pdf_fn(stem_sth),
                    x_max=args.x_max,
                    max_hot=args.max_hot,
                    shared_vmax=single_vmax if single_vmax > 0 else None,
                )


if __name__ == "__main__":
    main()
