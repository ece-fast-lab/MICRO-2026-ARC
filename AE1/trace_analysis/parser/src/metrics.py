"""Per-page continuity/intensity metrics plus trigger-based migration metrics."""

from __future__ import annotations

from dataclasses import dataclass
import math
from pathlib import Path
from typing import Optional

import numpy as np
import pandas as pd

try:
    from .pages import PageEventAccumulator, scan_pages_with_windows
except ImportError:
    from pages import PageEventAccumulator, scan_pages_with_windows


@dataclass(frozen=True)
class WindowSpec:
    label: str
    ticks: int


def _parse_duration_to_ticks(token: str, freq_mhz: Optional[float]) -> int:
    raw = token.strip().lower()
    if raw.endswith("us"):
        if freq_mhz is None:
            raise ValueError(f"Duration '{token}' requires --freq-mhz.")
        value_us = float(raw[:-2])
        ticks = int(round(value_us * freq_mhz))
    elif raw.endswith("ms"):
        if freq_mhz is None:
            raise ValueError(f"Duration '{token}' requires --freq-mhz.")
        value_us = float(raw[:-2]) * 1000.0
        ticks = int(round(value_us * freq_mhz))
    elif raw.endswith("s"):
        if freq_mhz is None:
            raise ValueError(f"Duration '{token}' requires --freq-mhz.")
        value_us = float(raw[:-1]) * 1_000_000.0
        ticks = int(round(value_us * freq_mhz))
    elif raw.endswith("ticks"):
        ticks = int(raw[:-5])
    elif raw.endswith("t"):
        ticks = int(raw[:-1])
    else:
        ticks = int(raw)

    if ticks < 0:
        raise ValueError(f"Duration '{token}' produced negative tick size.")
    return ticks


def parse_window_specs(windows: list[str], freq_mhz: Optional[float]) -> list[WindowSpec]:
    specs: list[WindowSpec] = []
    for raw in windows:
        token = raw.strip()
        if not token:
            continue
        specs.append(WindowSpec(label=token, ticks=_parse_duration_to_ticks(token, freq_mhz)))
    if not specs:
        raise ValueError("No valid windows were provided.")
    return specs


def parse_horizon_ticks(horizon: str, freq_mhz: Optional[float]) -> int:
    return _parse_duration_to_ticks(horizon, freq_mhz)


def _streak_lengths(active_bins_sorted: np.ndarray) -> np.ndarray:
    if active_bins_sorted.size == 0:
        return np.array([], dtype=np.int64)
    if active_bins_sorted.size == 1:
        return np.array([1], dtype=np.int64)

    diffs = np.diff(active_bins_sorted)
    breakpoints = np.where(diffs != 1)[0]
    starts = np.concatenate(([0], breakpoints + 1))
    ends = np.concatenate((breakpoints, [active_bins_sorted.size - 1]))
    return (ends - starts + 1).astype(np.int64)


def _trigger_indices(active_bins_sorted: np.ndarray) -> np.ndarray:
    if active_bins_sorted.size == 0:
        return np.array([], dtype=np.int64)
    if active_bins_sorted.size == 1:
        return np.array([active_bins_sorted[0]], dtype=np.int64)

    diffs = np.diff(active_bins_sorted)
    starts = np.where(diffs != 1)[0] + 1
    trigger_pos = np.concatenate(([0], starts))
    return active_bins_sorted[trigger_pos]


def _compute_w90_ticks(
    bin_idx: np.ndarray, sorted_counts: np.ndarray, window_ticks: int, total_accesses: int
) -> int:
    """Minimum time span (in ticks) of a contiguous set of bins containing >= 90% of accesses."""
    target = math.ceil(0.9 * total_accesses)
    n = len(bin_idx)
    if n == 0:
        return 0
    if n == 1:
        return window_ticks

    left = 0
    window_sum = 0
    min_span = int(bin_idx[-1] - bin_idx[0] + 1) * window_ticks  # fallback = full span

    for right in range(n):
        window_sum += int(sorted_counts[right])
        while window_sum >= target:
            span = int(bin_idx[right] - bin_idx[left] + 1) * window_ticks
            if span < min_span:
                min_span = span
            window_sum -= int(sorted_counts[left])
            left += 1

    return min_span


def _classify_pages(df: pd.DataFrame) -> pd.DataFrame:
    if df.empty:
        out = df.copy()
        out["page_class"] = []
        return out

    parts: list[pd.DataFrame] = []
    for _, g in df.groupby("window", sort=False):
        g = g.copy()
        intensity = g["avg_active_window_rate"]
        continuity = g["duty_cycle"]
        burst = g["peak_to_mean"]

        hot_int = float(intensity.quantile(0.80))
        warm_int = float(intensity.quantile(0.50))
        high_cont = float(continuity.quantile(0.60))
        burst_q = float(burst.quantile(0.75))

        classes = []
        for _, row in g.iterrows():
            i = float(row["avg_active_window_rate"])
            c = float(row["duty_cycle"])
            b = float(row["peak_to_mean"])

            if i >= hot_int and c >= high_cont:
                classes.append("persistent-hot")
            elif i >= hot_int and b >= burst_q:
                classes.append("burst-hot")
            elif i >= warm_int and c >= high_cont:
                classes.append("persistent-warm")
            else:
                classes.append("cold")

        g["page_class"] = classes
        parts.append(g)

    return pd.concat(parts, ignore_index=True)


def build_page_and_bin_dataframes(
    input_bin: Path,
    window_specs: list[WindowSpec],
    horizon_ticks: int,
    migration_cost: float,
    delta_access_cost: float,
    chunk_size: int = 1024 * 1024,
    start_ticks: Optional[int] = None,
    end_ticks: Optional[int] = None,
    downsample_n: int = 1,
) -> tuple[pd.DataFrame, pd.DataFrame]:
    if delta_access_cost <= 0:
        raise ValueError("delta_access_cost must be > 0.")
    if migration_cost < 0:
        raise ValueError("migration_cost must be >= 0.")

    window_ticks_by_label = {w.label: w.ticks for w in window_specs}
    pages, scan_state = scan_pages_with_windows(
        input_bin=input_bin,
        window_ticks_by_label=window_ticks_by_label,
        chunk_size=chunk_size,
        start_ticks=start_ticks,
        end_ticks=end_ticks,
        downsample_n=downsample_n,
    )

    global_span = scan_state.last_valid_ts - scan_state.first_valid_ts
    total_bins_by_label = {
        label: max(1, math.ceil(global_span / ticks)) for label, ticks in window_ticks_by_label.items()
    }
    accesses_needed = float(migration_cost) / float(delta_access_cost)

    page_rows: list[dict[str, float | int | str]] = []
    bin_rows: list[dict[str, float | int | str | None]] = []

    for page_num, acc in pages.items():
        total_accesses = acc.total_accesses
        first_ts = int(acc.first_ts) if acc.first_ts is not None else 0
        last_ts = int(acc.last_ts) if acc.last_ts is not None else 0
        active_span = last_ts - first_ts if total_accesses > 0 else 0
        read_count = acc.read_count
        write_count = acc.write_count
        read_ratio = float(read_count) / float(total_accesses) if total_accesses else 0.0
        write_ratio = float(write_count) / float(total_accesses) if total_accesses else 0.0

        # Compute W90 using the finest available window (smallest ticks).
        finest_spec = min(window_specs, key=lambda s: s.ticks)
        finest_bins = acc.window_bin_counts.get(finest_spec.label, {})
        if finest_bins and total_accesses > 0:
            _bidx = np.sort(np.fromiter(finest_bins.keys(), dtype=np.int64))
            _bcnt = np.array([finest_bins[int(b)] for b in _bidx], dtype=np.int64)
            w90_ticks: int = _compute_w90_ticks(_bidx, _bcnt, finest_spec.ticks, total_accesses)
        else:
            w90_ticks = int(active_span)

        for spec in window_specs:
            bins = acc.window_bin_counts[spec.label]
            total_bins = total_bins_by_label[spec.label]
            active_bins = len(bins)
            if active_bins == 0:
                continue

            counts = np.fromiter(bins.values(), dtype=np.int64)
            bin_idx = np.sort(np.fromiter(bins.keys(), dtype=np.int64))
            # Align counts with sorted indices.
            count_map = bins
            sorted_counts = np.array([count_map[int(b)] for b in bin_idx], dtype=np.int64)
            prefix = np.cumsum(sorted_counts, dtype=np.int64)
            streak_lengths = _streak_lengths(bin_idx)
            triggers = _trigger_indices(bin_idx)
            trigger_set = set(int(x) for x in triggers.tolist())

            mean_all = float(total_accesses) / float(total_bins)
            sum_sq = float(np.dot(sorted_counts, sorted_counts))
            ex2 = sum_sq / float(total_bins)
            variance = max(0.0, ex2 - mean_all * mean_all)
            stddev = float(np.sqrt(variance))
            peak = float(sorted_counts.max())
            mean_active = float(sorted_counts.mean())

            duty_cycle = float(active_bins) / float(total_bins)
            longest_streak = float(streak_lengths.max()) if streak_lengths.size else 0.0
            avg_streak = float(streak_lengths.mean()) if streak_lengths.size else 0.0
            peak_access_rate = peak / float(spec.ticks)
            avg_active_rate = mean_active / float(spec.ticks)
            burstiness_cv = (stddev / mean_all) if mean_all > 0 else 0.0
            burstiness_fano = (variance / mean_all) if mean_all > 0 else 0.0
            peak_to_mean = (peak / mean_all) if mean_all > 0 else 0.0

            horizon_bins = int(math.ceil(horizon_ticks / float(spec.ticks)))
            future_reuse_values: list[float] = []
            ttp_values: list[float] = []
            payback_values: list[float] = []

            for idx, b in enumerate(bin_idx):
                b_int = int(b)
                is_trigger = b_int in trigger_set

                trig_future_reuse = None
                trig_ttp = None
                trig_payback = None
                if is_trigger:
                    # Trigger-based future reuse in [t, t+H] in bin space.
                    end_bin = b_int + horizon_bins - 1
                    end_pos = int(np.searchsorted(bin_idx, end_bin, side="right")) - 1
                    if end_pos >= idx:
                        future_accesses = int(prefix[end_pos] - (prefix[idx - 1] if idx > 0 else 0))
                    else:
                        future_accesses = 0

                    trig_future_reuse = float(future_accesses)
                    trig_payback = float(future_accesses) * float(delta_access_cost) - float(
                        migration_cost
                    )

                    # Trigger-based time to payback.
                    if accesses_needed <= 0:
                        trig_ttp = 0.0
                    else:
                        needed_cum = (prefix[idx - 1] if idx > 0 else 0) + accesses_needed
                        hit_pos = int(np.searchsorted(prefix, needed_cum, side="left"))
                        if hit_pos < prefix.size:
                            trig_ttp = float((int(bin_idx[hit_pos]) - b_int + 1) * spec.ticks)
                        else:
                            trig_ttp = float("inf")

                    future_reuse_values.append(trig_future_reuse)
                    ttp_values.append(trig_ttp)
                    payback_values.append(trig_payback)

                bin_rows.append(
                    {
                        "page_number": int(page_num),
                        "window": spec.label,
                        "window_ticks": int(spec.ticks),
                        "bin_index": b_int,
                        "bin_start_elapsed_ticks": int(b_int * spec.ticks),
                        "bin_end_elapsed_ticks": int((b_int + 1) * spec.ticks - 1),
                        "bin_count": int(sorted_counts[idx]),
                        "is_active": 1,
                        "is_trigger": 1 if is_trigger else 0,
                        "trigger_future_reuse_within_H": trig_future_reuse,
                        "trigger_time_to_payback_ticks": trig_ttp,
                        "trigger_payback_score": trig_payback,
                    }
                )

            finite_ttp = [x for x in ttp_values if np.isfinite(x)]
            page_rows.append(
                {
                    "page_number": int(page_num),
                    "window": spec.label,
                    "window_ticks": int(spec.ticks),
                    "total_accesses": int(total_accesses),
                    "first_ts": int(first_ts),
                    "last_ts": int(last_ts),
                    "active_span": int(active_span),
                    "duty_cycle": float(duty_cycle),
                    "longest_active_streak": float(longest_streak),
                    "average_active_streak": float(avg_streak),
                    "peak_access_rate": float(peak_access_rate),
                    "avg_active_window_rate": float(avg_active_rate),
                    "burstiness_cv": float(burstiness_cv),
                    "burstiness_fano": float(burstiness_fano),
                    "peak_to_mean": float(peak_to_mean),
                    "read_count": int(read_count),
                    "write_count": int(write_count),
                    "read_ratio": float(read_ratio),
                    "write_ratio": float(write_ratio),
                    "trigger_count": int(len(future_reuse_values)),
                    "future_reuse_within_H_mean": float(np.mean(future_reuse_values))
                    if future_reuse_values
                    else 0.0,
                    "future_reuse_within_H_max": float(np.max(future_reuse_values))
                    if future_reuse_values
                    else 0.0,
                    "time_to_payback_best_ticks": float(np.min(finite_ttp))
                    if finite_ttp
                    else float("inf"),
                    "time_to_payback_mean_ticks": float(np.mean(finite_ttp))
                    if finite_ttp
                    else float("inf"),
                    "payback_score_mean": float(np.mean(payback_values))
                    if payback_values
                    else -float(migration_cost),
                    "payback_score_max": float(np.max(payback_values))
                    if payback_values
                    else -float(migration_cost),
                    "w90_ticks": int(w90_ticks),
                }
            )

    page_df = pd.DataFrame(page_rows)
    if page_df.empty:
        return page_df, pd.DataFrame(bin_rows)

    page_df = _classify_pages(page_df)
    page_df = page_df.sort_values(
        ["window_ticks", "total_accesses", "page_number"], ascending=[True, False, True]
    ).reset_index(drop=True)

    bin_df = pd.DataFrame(bin_rows).sort_values(
        ["window_ticks", "page_number", "bin_index"], ascending=[True, True, True]
    )
    return page_df, bin_df

