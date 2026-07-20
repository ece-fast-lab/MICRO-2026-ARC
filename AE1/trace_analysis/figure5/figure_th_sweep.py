"""
Figure 5 — per-algo threshold-sweep scatter (cum_scatter_b).

Trimmed from figure_th_cum.py: generates ONLY the cum_scatter_b figures
(one file per algorithm, subplots by threshold), so no byproduct PNGs land in
the output dir. Hot pages come from nonacc hotlists; displayed on the cumulative
scatter space (access_count vs W100 access rate).

Output (to --out-dir):
  {workload}_cum_scatter_b_lfu_ao_1ms_{start}ms-{end}ms.png
  {workload}_cum_scatter_b_cms_ee_1ms_{start}ms-{end}ms.png

Usage:
    python figure_th_sweep.py \\
        --outputs-dir outputs/gapbs_pr_twitter_t8_n10000000 \\
        --nonacc-dir  outputs/nonacc/gapbs_pr_twitter_t8_n10000000 \\
        --workload    gapbs_pr_twitter_t8_n10000000 \\
        --start-ms 10 --end-ms 11 \\
        --threshold 32 64 96 --max-hot 256 --x-max 128 \\
        --out-dir _work
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

_ALGO_LABELS = {
    "lfu_ao": "LFU (always-on)",
    "cms_ee": "CMS (epoch-end)",
}


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
# Per-algo scatter_b (one file per algo, subplots by threshold)
# ---------------------------------------------------------------------------

def _shared_scatter_b_norm(
    all_df: pd.DataFrame,
    algo_hotlists: dict[str, dict[int, pd.DataFrame]],
    thresholds: list[int],
    span_col: str,
    bin_count: int,
    max_hot: int | None = None,
    x_max: int | None = None,
) -> tuple[float, float]:
    """Compute global vmin/vmax across all algos and thresholds for unified colorbar."""
    acc_all = all_df["access_count"].to_numpy(dtype=float)
    w_all = all_df[span_col].to_numpy(dtype=float)
    bs_all = _access_rate(acc_all, w_all)
    base_mask = (acc_all > 0) & (w_all > 0) & np.isfinite(bs_all)
    x_edges = np.linspace(0, x_max, bin_count + 1) if x_max is not None else _even_edges(acc_all[base_mask], bin_count)
    y_edges = _log_edges(bs_all[base_mask], bin_count)

    n_epochs = all_df["epoch_idx"].nunique()
    denom = max_hot * n_epochs if (max_hot is not None and n_epochs > 0) else None

    global_vmin, global_vmax = np.inf, -np.inf
    for hbt in algo_hotlists.values():
        for th in thresholds:
            hot_df = hbt.get(th)
            if hot_df is None or hot_df.empty:
                continue
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
            acc, bs = acc[mask], bs[mask]
            if acc.size < 2:
                continue
            H, _, _ = np.histogram2d(acc, bs, bins=[x_edges, y_edges])
            Z = H.T / (denom if denom is not None else acc.size)
            valid = Z[np.isfinite(Z) & (Z > 0)]
            if valid.size:
                global_vmin = min(global_vmin, valid.min())
                global_vmax = max(global_vmax, valid.max())

    if not np.isfinite(global_vmax):
        global_vmin, global_vmax = 1e-4, 1.0
    return global_vmin, global_vmax


def figure_cum_scatter_b(
    all_df: pd.DataFrame,
    hotlist_by_th: dict[int, pd.DataFrame],  # th -> df with page_addr, epoch_idx
    algo_key: str,
    thresholds: list[int],
    out_png: Path,
    span_col: str = "active_span_us",
    bin_count: int = 20,
    out_pdf: Path | None = None,
    norm_vmin: float | None = None,
    norm_vmax: float | None = None,
    max_hot: int | None = None,
    x_max: int | None = None,
) -> None:
    """Per-algo, subplots by threshold; hot (page, epoch) pairs on per-epoch scatter space."""
    acc_all = all_df["access_count"].to_numpy(dtype=float)
    w_all = all_df[span_col].to_numpy(dtype=float)
    bs_all = _access_rate(acc_all, w_all)
    base_mask = (acc_all > 0) & (w_all > 0) & np.isfinite(bs_all)

    if base_mask.sum() < 2:
        print(f"Skipping {out_png.name}: insufficient base data")
        return

    n_epochs = all_df["epoch_idx"].nunique()
    denom = max_hot * n_epochs if (max_hot is not None and n_epochs > 0) else None

    x_edges = np.linspace(0, x_max, bin_count + 1) if x_max is not None else _even_edges(acc_all[base_mask], bin_count)
    y_edges = _log_edges(bs_all[base_mask], bin_count)

    density_maps: dict[int, tuple[np.ndarray, np.ndarray, np.ndarray]] = {}
    global_vmin, global_vmax = np.inf, -np.inf

    for th in thresholds:
        hot_df = hotlist_by_th.get(th)
        if hot_df is None or hot_df.empty:
            continue
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
        acc, bs = acc[mask], bs[mask]
        if acc.size < 2:
            continue
        H, xedges, yedges = np.histogram2d(acc, bs, bins=[x_edges, y_edges])
        Z = H.T / (denom if denom is not None else acc.size)
        Z[Z == 0] = np.nan
        density_maps[th] = (Z, xedges, yedges)
        valid = Z[np.isfinite(Z) & (Z > 0)]
        if valid.size:
            global_vmin = min(global_vmin, valid.min())
            global_vmax = max(global_vmax, valid.max())

    if not density_maps:
        print(f"Skipping {out_png.name}: no valid hotlist data")
        return

    # Use caller-supplied range if provided (for cross-algo colorbar unification)
    if norm_vmin is not None and norm_vmax is not None:
        global_vmin, global_vmax = norm_vmin, norm_vmax
    elif not np.isfinite(global_vmax):
        global_vmax, global_vmin = 1.0, 1e-4

    n_th = len(thresholds)
    subplot_w = (_FIG_W_IN - 0.6) / n_th
    fig_h = subplot_w + 0.8
    fig, axes = plt.subplots(1, n_th, figsize=(_FIG_W_IN, fig_h), sharey=True, layout="constrained")
    if n_th == 1:
        axes = [axes]
    fig.get_layout_engine().set(wspace=0.06, w_pad=0.02)

    cmap = _make_cmap()
    norm = mcolors.Normalize(vmin=global_vmin, vmax=global_vmax)

    pcm_last = None
    for ax, th in zip(axes, thresholds):
        _setup_ax(ax, x_edges, y_edges, xlabel=False)
        ax.set_title(f"th={th}", fontsize=12)
        if th in density_maps:
            Z, xedges, yedges = density_maps[th]
            pcm_last = ax.pcolormesh(xedges, yedges, Z, cmap=cmap, norm=norm)

    axes[0].set_ylabel("Burstiness (accesses/s)")
    fig.supxlabel("Access count", fontsize=12, y=0.05)
    if pcm_last is not None:
        cax = axes[-1].inset_axes([1.05, 0, 0.05, 1])
        cb = fig.colorbar(pcm_last, cax=cax, label="Hot page ratio")
        cb.ax.yaxis.set_major_locator(mpl.ticker.MultipleLocator(0.1))
    fig.patch.set_facecolor("white")

    _save(fig, out_png, out_pdf)


# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------

def main() -> None:
    parser = argparse.ArgumentParser(
        description="Figure 5: per-algo threshold-sweep scatter (cum_scatter_b only)"
    )
    parser.add_argument("--outputs-dir", required=True,
                        help="Dir with {workload}_all_1ms_0ms-{N}ms.csv")
    parser.add_argument("--nonacc-dir", required=True,
                        help="Dir with *_nonacc_hotlist_*.csv")
    parser.add_argument("--workload", required=True)
    parser.add_argument("--end-ms", type=int, nargs="+", default=[1, 10, 100])
    parser.add_argument("--start-ms", type=int, nargs="+", default=None,
                        help="Start time(s) in ms (paired with --end-ms; default: 0 for all)")
    parser.add_argument("--threshold", type=int, nargs="+", default=[32, 64, 96])
    parser.add_argument("--max-hot", type=int, default=None,
                        help="Max hot pages per epoch used in hotlist CSVs (e.g. 256)")
    parser.add_argument("--bin-count", type=int, default=20)
    parser.add_argument("--x-max", type=int, default=None,
                        help="Fix x-axis max (access count); e.g. 128")
    parser.add_argument("--out-dir", default="_work")
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

        # Pass 1: load hotlists for both algos, compute shared vmin/vmax
        algo_hotlists: dict[str, dict[int, pd.DataFrame]] = {}
        for algo_key in ("lfu_ao", "cms_ee"):
            hbt: dict[int, pd.DataFrame] = {}
            for th in args.threshold:
                stem = f"{args.workload}_nonacc_hotlist_{algo_key}_th{th}{maxhot_tag}_{suffix}.csv"
                hot_path = _resolve_csv(nonacc_dir / stem)
                if hot_path is not None:
                    hbt[th] = pd.read_csv(hot_path)
                else:
                    print(f"  Missing: {stem}[.gz]")
            if hbt:
                algo_hotlists[algo_key] = hbt

        shared_vmin, shared_vmax = _shared_scatter_b_norm(
            all_df, algo_hotlists, args.threshold, span_col, args.bin_count,
            max_hot=args.max_hot, x_max=args.x_max,
        )

        # Pass 2: render one file per algo with shared norm
        for algo_key, hbt in algo_hotlists.items():
            stem_sb = f"{args.workload}_cum_scatter_b_{algo_key}_{suffix}"
            figure_cum_scatter_b(
                all_df,
                hotlist_by_th=hbt,
                algo_key=algo_key,
                thresholds=args.threshold,
                out_png=out_dir / f"{stem_sb}.png",
                span_col=span_col,
                bin_count=args.bin_count,
                out_pdf=pdf_fn(stem_sb),
                norm_vmin=shared_vmin,
                norm_vmax=shared_vmax,
                max_hot=args.max_hot,
                x_max=args.x_max,
            )


if __name__ == "__main__":
    main()
