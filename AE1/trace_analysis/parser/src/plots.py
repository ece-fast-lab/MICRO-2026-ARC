"""Plot generation for page-level analysis outputs."""

from __future__ import annotations

from pathlib import Path
from typing import Optional

import numpy as np
import pandas as pd
import matplotlib.pyplot as plt
from mpl_toolkits.mplot3d import Axes3D  # noqa: F401
from matplotlib.colors import LinearSegmentedColormap


CLASS_COLORS = {
    "persistent-hot": "#d73027",
    "burst-hot": "#fc8d59",
    "persistent-warm": "#fee08b",
    "cold": "#91bfdb",
}


def _select_plot_window(df: pd.DataFrame, preferred_window: str) -> pd.DataFrame:
    if df.empty:
        return df
    if preferred_window in set(df["window"].astype(str)):
        return df[df["window"] == preferred_window].copy()
    min_ticks = df["window_ticks"].min()
    return df[df["window_ticks"] == min_ticks].copy()


def plot_continuity_vs_intensity(
    page_df: pd.DataFrame,
    output_png: Path,
    preferred_window: str,
    hot_page_set: Optional[set] = None,
    scheme_label: str = "all",
    time_range_label: str = "",
    xlim: Optional[tuple] = None,
    ylim: Optional[tuple] = None,
    hot_list_count: Optional[int] = None,
) -> None:
    g = _select_plot_window(page_df, preferred_window)
    if hot_page_set is not None and not g.empty:
        g = g[g["page_number"].isin(hot_page_set)].copy()

    total_accesses = int(g["total_accesses"].sum()) if not g.empty else 0
    unique_addrs = len(g)

    fig, ax = plt.subplots(figsize=(9, 6))
    legend = None
    if not g.empty:
        for klass, sub in g.groupby("page_class", sort=False):
            ax.scatter(
                sub["duty_cycle"],
                sub["total_accesses"],
                s=14,
                alpha=0.65,
                color=CLASS_COLORS.get(str(klass), "#666666"),
                label=str(klass),
            )
        legend = ax.legend(loc="lower right", frameon=False, fontsize=9)
    if xlim is not None:
        ax.set_xlim(xlim)
    if ylim is not None:
        ax.set_ylim(ylim)
    ax.set_xlabel("Continuity (duty_cycle)")
    ax.set_ylabel("Total accesses")
    time_part = f"  {time_range_label}" if time_range_label else ""
    ax.set_title(f"Continuity vs Intensity  [{scheme_label}  window={preferred_window}{time_part}]")

    # Stats annotation: above the legend, aligned to the right
    lines = [f"Total accesses: {total_accesses:,}", f"Unique addrs: {unique_addrs:,}"]
    if hot_list_count is not None:
        lines.append(f"Hot list entries: {hot_list_count:,}")

    fig.canvas.draw()
    if legend is not None:
        try:
            bb = legend.get_window_extent(renderer=fig.canvas.get_renderer())
            text_y = bb.transformed(ax.transAxes.inverted()).y1 + 0.01
        except Exception:
            text_y = 0.30
    else:
        text_y = 0.30
    ax.text(
        0.98, text_y, "\n".join(lines),
        transform=ax.transAxes,
        va="bottom", ha="right", fontsize=8,
        bbox=dict(boxstyle="round,pad=0.3", facecolor="white", alpha=0.75, edgecolor="grey"),
    )

    plt.tight_layout()
    output_png.parent.mkdir(parents=True, exist_ok=True)
    plt.savefig(output_png, dpi=180)
    plt.close()


def plot_page_count_heatmap(
    page_df: pd.DataFrame,
    output_png: Path,
    preferred_window: str,
    hot_page_set: Optional[set] = None,
    scheme_label: str = "all",
    time_range_label: str = "",
    xlim: Optional[tuple] = None,
    ylim: Optional[tuple] = None,
    vmax: Optional[float] = None,
) -> None:
    g = _select_plot_window(page_df, preferred_window)
    if hot_page_set is not None and not g.empty:
        g = g[g["page_number"].isin(hot_page_set)].copy()
    fig, ax = plt.subplots(figsize=(8, 6))
    ax.set_facecolor("grey")
    cmap = LinearSegmentedColormap.from_list("white_orange", ["white", "#ff8c00"])
    cmap.set_under("grey")
    if not g.empty:
        x = g["duty_cycle"].to_numpy(dtype=float)
        y = g["total_accesses"].to_numpy(dtype=float)
        hist_range = [list(xlim), list(ylim)] if xlim is not None and ylim is not None else None
        _, _, _, im = ax.hist2d(x, y, bins=(40, 40), cmap=cmap, vmin=1, vmax=vmax,
                                range=hist_range)
        cbar = fig.colorbar(im, ax=ax)
        cbar.set_label("Page count")
    else:
        # Empty: draw a blank image with fixed scale so colorbar is consistent
        dummy = ax.imshow([[0]], cmap=cmap, vmin=1, vmax=vmax or 1, aspect="auto")
        fig.colorbar(dummy, ax=ax).set_label("Page count")
    ax.set_ylabel("Total accesses")
    ax.set_xlabel("Continuity (duty_cycle)")
    if xlim is not None:
        ax.set_xlim(xlim)
    if ylim is not None:
        ax.set_ylim(ylim)
    time_part = f"  {time_range_label}" if time_range_label else ""
    ax.set_title(f"Page Count Heatmap  [{scheme_label}  window={preferred_window}{time_part}]")
    plt.tight_layout()
    output_png.parent.mkdir(parents=True, exist_ok=True)
    plt.savefig(output_png, dpi=180)
    plt.close()


def plot_3d_page_density(
    page_df: pd.DataFrame,
    output_png: Path,
    preferred_window: str,
    bins: int = 40,
    hot_page_set: Optional[set] = None,
    scheme_label: str = "all",
    z_max: Optional[float] = None,
    time_range_label: str = "",
) -> float:
    """Plot 3D page density.

    Returns the z_max (log10 page count) used for the colorbar, so callers
    can pass it to subsequent plots for a consistent colour scale.
    """
    g = _select_plot_window(page_df, preferred_window)
    if hot_page_set is not None and not g.empty:
        g = g[g["page_number"].isin(hot_page_set)].copy()
    fig = plt.figure(figsize=(12, 8))
    ax = fig.add_subplot(111, projection="3d")

    effective_z_max = z_max if z_max is not None else 0.0

    if not g.empty:
        window_ticks = float(g["window_ticks"].iloc[0])
        x = g["duty_cycle"].to_numpy(dtype=float)
        y_acc = g["avg_active_window_rate"].to_numpy(dtype=float) * window_ticks
        y_acc = np.clip(y_acc, 0.1, None)
        ylog = np.log10(y_acc)

        counts, xedges, yedges = np.histogram2d(x, ylog, bins=bins)

        xmid = (xedges[:-1] + xedges[1:]) / 2
        ymid = (yedges[:-1] + yedges[1:]) / 2
        X, Y = np.meshgrid(xmid, ymid, indexing="ij")

        Z = np.where(counts > 0, np.log10(np.where(counts > 0, counts, 1.0)), 0.0)

        if z_max is None:
            effective_z_max = float(Z.max()) if Z.max() > 0 else 1.0
        else:
            effective_z_max = z_max

        cmap = LinearSegmentedColormap.from_list("white_orange", ["white", "#ff8c00"])
        norm = plt.Normalize(vmin=0, vmax=effective_z_max)
        facecolors = cmap(norm(Z))

        ax.plot_surface(X, Y, Z, facecolors=facecolors, shade=True,
                        rstride=1, cstride=1, alpha=0.95, linewidth=0)

        mappable = plt.cm.ScalarMappable(cmap=cmap, norm=norm)
        mappable.set_array(Z)
        cbar = fig.colorbar(mappable, ax=ax, shrink=0.5, label="Page count")
        tick_vals = np.linspace(0, effective_z_max, 5)
        cbar.set_ticks(tick_vals)
        cbar.set_ticklabels([f"{10**v:.0f}" for v in tick_vals])

        ytick_log = np.linspace(yedges[0], yedges[-1], 6)
        ax.set_yticks(ytick_log)
        ax.set_yticklabels([f"{10**v:.1f}" for v in ytick_log])

    ax.invert_yaxis()
    ax.set_xlabel("Continuity (duty_cycle)")
    ax.set_ylabel("Avg accesses per active window")
    ax.set_zlabel("log10(Number of Pages)")
    time_part = f"  {time_range_label}" if time_range_label else ""
    ax.set_title(f"3D Page Density  [{scheme_label}  window={preferred_window}{time_part}]")
    plt.tight_layout()
    output_png.parent.mkdir(parents=True, exist_ok=True)
    plt.savefig(output_png, dpi=180)
    plt.close()
    return effective_z_max


def plot_continuity_sweep(
    page_df: pd.DataFrame,
    output_png: Path,
    preferred_window: str,
    sweep_items: list,
    xlim: Optional[tuple] = None,
    ylim: Optional[tuple] = None,
    time_range_label: str = "",
    suptitle: str = "",
) -> None:
    """2×N continuity scatter combining multiple threshold variants into one PNG.

    sweep_items: list of dicts with keys: label (str), hot_page_set (set|None),
                 hot_list_count (int|None).
    """
    n = len(sweep_items)
    ncols = 2
    nrows = (n + ncols - 1) // ncols
    fig, axes = plt.subplots(nrows, ncols, figsize=(16, 6 * nrows), squeeze=False)

    legend_data = []  # (legend_obj, ax, text_str)
    for idx, item in enumerate(sweep_items):
        ax = axes.flat[idx]
        g = _select_plot_window(page_df, preferred_window)
        hot_set = item.get("hot_page_set")
        if hot_set is not None and not g.empty:
            g = g[g["page_number"].isin(hot_set)].copy()

        total_accesses = int(g["total_accesses"].sum()) if not g.empty else 0
        unique_addrs = len(g)
        hot_list_count = item.get("hot_list_count")

        legend = None
        if not g.empty:
            for klass, sub in g.groupby("page_class", sort=False):
                ax.scatter(sub["duty_cycle"], sub["total_accesses"],
                           s=10, alpha=0.6,
                           color=CLASS_COLORS.get(str(klass), "#666666"),
                           label=str(klass))
            legend = ax.legend(loc="lower right", frameon=False, fontsize=8)

        if xlim is not None:
            ax.set_xlim(xlim)
        if ylim is not None:
            ax.set_ylim(ylim)
        ax.set_xlabel("Continuity (duty_cycle)", fontsize=8)
        ax.set_ylabel("Total accesses", fontsize=8)
        time_part = f"  {time_range_label}" if time_range_label else ""
        ax.set_title(f"{item['label']}  [window={preferred_window}{time_part}]", fontsize=9)

        lines = [f"Total accesses: {total_accesses:,}", f"Unique addrs: {unique_addrs:,}"]
        if hot_list_count is not None:
            lines.append(f"Hot list entries: {hot_list_count:,}")
        legend_data.append((legend, ax, "\n".join(lines)))

    for idx in range(n, nrows * ncols):
        axes.flat[idx].set_visible(False)

    if suptitle:
        fig.suptitle(suptitle, fontsize=11)

    fig.canvas.draw()
    renderer = fig.canvas.get_renderer()
    for legend, ax, text in legend_data:
        if legend is not None:
            try:
                bb = legend.get_window_extent(renderer=renderer)
                text_y = bb.transformed(ax.transAxes.inverted()).y1 + 0.01
            except Exception:
                text_y = 0.30
        else:
            text_y = 0.30
        ax.text(0.98, text_y, text, transform=ax.transAxes,
                va="bottom", ha="right", fontsize=7,
                bbox=dict(boxstyle="round,pad=0.3", facecolor="white", alpha=0.75, edgecolor="grey"))

    plt.tight_layout()
    output_png.parent.mkdir(parents=True, exist_ok=True)
    plt.savefig(output_png, dpi=150, bbox_inches="tight")
    plt.close()


def plot_heatmap_sweep(
    page_df: pd.DataFrame,
    output_png: Path,
    preferred_window: str,
    sweep_items: list,
    xlim: Optional[tuple] = None,
    ylim: Optional[tuple] = None,
    time_range_label: str = "",
    vmax: Optional[float] = None,
    suptitle: str = "",
) -> None:
    """2×N heatmap combining multiple threshold variants into one PNG."""
    n = len(sweep_items)
    ncols = 2
    nrows = (n + ncols - 1) // ncols
    fig, axes = plt.subplots(nrows, ncols, figsize=(14, 6 * nrows), squeeze=False)
    cmap = LinearSegmentedColormap.from_list("white_orange", ["white", "#ff8c00"])
    cmap.set_under("grey")

    for idx, item in enumerate(sweep_items):
        ax = axes.flat[idx]
        ax.set_facecolor("grey")
        g = _select_plot_window(page_df, preferred_window)
        hot_set = item.get("hot_page_set")
        if hot_set is not None and not g.empty:
            g = g[g["page_number"].isin(hot_set)].copy()

        if not g.empty:
            x = g["duty_cycle"].to_numpy(dtype=float)
            y = g["total_accesses"].to_numpy(dtype=float)
            hist_range = [list(xlim), list(ylim)] if xlim is not None and ylim is not None else None
            _, _, _, im = ax.hist2d(x, y, bins=(40, 40), cmap=cmap, vmin=1, vmax=vmax,
                                    range=hist_range)
            cbar = fig.colorbar(im, ax=ax)
            cbar.set_label("Page count", fontsize=7)
        else:
            dummy = ax.imshow([[0]], cmap=cmap, vmin=1, vmax=vmax or 1, aspect="auto")
            fig.colorbar(dummy, ax=ax).set_label("Page count", fontsize=7)

        if xlim is not None:
            ax.set_xlim(xlim)
        if ylim is not None:
            ax.set_ylim(ylim)
        ax.set_xlabel("Continuity (duty_cycle)", fontsize=8)
        ax.set_ylabel("Total accesses", fontsize=8)
        time_part = f"  {time_range_label}" if time_range_label else ""
        ax.set_title(f"{item['label']}  [window={preferred_window}{time_part}]", fontsize=9)

    for idx in range(n, nrows * ncols):
        axes.flat[idx].set_visible(False)

    if suptitle:
        fig.suptitle(suptitle, fontsize=11)

    plt.tight_layout()
    output_png.parent.mkdir(parents=True, exist_ok=True)
    plt.savefig(output_png, dpi=150, bbox_inches="tight")
    plt.close()


def plot_time_to_payback_cdf(
    page_df: pd.DataFrame, output_png: Path, preferred_window: str
) -> None:
    g = _select_plot_window(page_df, preferred_window)
    values = np.array([], dtype=float)
    if not g.empty and "time_to_payback_best_ticks" in g.columns:
        raw = g["time_to_payback_best_ticks"].to_numpy(dtype=float)
        values = raw[np.isfinite(raw)]
        values = np.sort(values)

    plt.figure(figsize=(8, 5))
    if values.size > 0:
        y = np.arange(1, values.size + 1, dtype=float) / float(values.size)
        plt.plot(values, y, color="#1f77b4", linewidth=2.0)
    plt.xlabel("Best Time-to-Payback (ticks)")
    plt.ylabel("CDF")
    plt.title("Time-to-Payback CDF")
    plt.tight_layout()
    output_png.parent.mkdir(parents=True, exist_ok=True)
    plt.savefig(output_png, dpi=180)
    plt.close()

