"""
Non-cumulative per-epoch data extractor.

Scans the trace ONCE and extracts per-1ms-epoch access counts from
window_bin_counts. Each (page, epoch) is an independent data point.

  active_time_us = epoch_length_us (1000) fixed for any active epoch.
  hotlist: page is hot in epoch k if count_in_k >= threshold  (epoch-end logic).

Outputs to --out-dir:
  {workload}_nonacc_all_1ms_0ms-{N}ms.csv
      columns: page_addr, epoch_idx, access_count, active_time_us
  {workload}_nonacc_hotlist_th{th}_1ms_0ms-{N}ms.csv
      columns: page_addr, epoch_idx

Usage:
    python pdf_parser/gen_nonacc.py \\
        --trace /fast-lab-share/cxl_traces/traces/gapbs/gapbs_pr_twitter_t8_n10000000.bin \\
        --workload gapbs_pr_twitter_t8_n10000000 \\
        --end-ms 100 \\
        --threshold 16 32 64 96 \\
        --out-dir outputs/nonacc/gapbs_pr_twitter_t8_n10000000
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

import pandas as pd

sys.path.insert(0, str(Path(__file__).parent.parent))
from src.pages import scan_pages_with_windows
from src.metrics import parse_window_specs, parse_horizon_ticks

FREQ_MHZ = 400
EPOCH_LABEL = "1ms"
EPOCH_US = 1000.0  # fixed active_time per epoch


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Extract non-cumulative per-epoch CSVs from a trace file"
    )
    parser.add_argument("--trace", required=True, help="Path to .bin trace file")
    parser.add_argument("--workload", required=True, help="Workload name prefix")
    parser.add_argument("--end-ms", type=int, nargs="+", default=[1, 10, 100],
                        help="End time(s) in ms to output (default: 1 10 100)")
    parser.add_argument("--start-ms", type=int, nargs="+", default=None,
                        help="Start time(s) in ms (paired with --end-ms; default: 0 for all)")
    parser.add_argument("--threshold", type=int, nargs="+", default=[16, 32, 64, 96],
                        help="Threshold(s) for hotlist (default: 16 32 64 96)")
    parser.add_argument("--max-hot", type=int, default=None,
                        help="Max hot pages per epoch (top-N by access_count; default: unlimited)")
    parser.add_argument("--freq-mhz", type=float, default=FREQ_MHZ)
    parser.add_argument("--out-dir", default="outputs/nonacc")
    args = parser.parse_args()

    trace = Path(args.trace)
    out_dir = Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    freq = args.freq_mhz

    max_end_ms = max(args.end_ms)
    epoch_ticks = int(EPOCH_US * freq)
    end_ticks = int(max_end_ms * 1000 * freq)

    print(f"Scanning {trace.name} up to {max_end_ms}ms ...")
    pages, scan_state = scan_pages_with_windows(
        trace,
        window_ticks_by_label={EPOCH_LABEL: epoch_ticks},
        end_ticks=end_ticks,
    )
    print(f"  Done. {len(pages)} unique pages, {scan_state.valid_records} valid records.")

    # Build flat DataFrame: one row per (page, epoch)
    rows = []
    for page_addr, acc in pages.items():
        bin_counts = acc.window_bin_counts.get(EPOCH_LABEL, {})
        bin_first = acc.window_bin_first_ts.get(EPOCH_LABEL, {})
        bin_last = acc.window_bin_last_ts.get(EPOCH_LABEL, {})
        for bin_idx, count in bin_counts.items():
            ft = bin_first.get(bin_idx)
            lt = bin_last.get(bin_idx)
            span_us = (lt - ft) / freq if (ft is not None and lt is not None and lt > ft) else 0.0
            rows.append({
                "page_addr": int(page_addr),
                "epoch_idx": int(bin_idx),
                "access_count": int(count),
                "active_time_us": EPOCH_US,
                "active_span_us": span_us,
            })

    if not rows:
        print("No data extracted.")
        return

    df = pd.DataFrame(rows)
    print(f"  Extracted {len(df)} (page, epoch) rows across {df['epoch_idx'].nunique()} epochs.")

    # Build (start_ms, end_ms) pairs
    if args.start_ms is not None:
        if len(args.start_ms) != len(args.end_ms):
            raise ValueError("--start-ms and --end-ms must have the same number of values")
        time_ranges = sorted(zip(args.start_ms, args.end_ms))
    else:
        time_ranges = [(0, e) for e in sorted(args.end_ms)]

    for start_ms, end_ms in time_ranges:
        start_epoch = int(start_ms * 1000 / EPOCH_US)
        end_epoch = int(end_ms * 1000 / EPOCH_US)
        sub = df[(df["epoch_idx"] >= start_epoch) & (df["epoch_idx"] < end_epoch)].copy()
        sub = sub.sort_values(["epoch_idx", "access_count"], ascending=[True, False]).reset_index(drop=True)

        range_tag = f"{start_ms}ms-{end_ms}ms"
        # all CSV
        all_path = out_dir / f"{args.workload}_nonacc_all_1ms_{range_tag}.csv"
        sub.to_csv(all_path, index=False)
        print(f"Wrote {all_path.name}  ({len(sub)} rows, {sub['epoch_idx'].nunique()} epochs)")

        # hotlist CSVs per threshold
        maxhot_tag = f"_maxhot{args.max_hot}" if args.max_hot is not None else ""
        for th in args.threshold:
            hot = sub[sub["access_count"] >= th][["page_addr", "epoch_idx", "access_count"]].copy()
            if args.max_hot is not None:
                hot = hot.groupby("epoch_idx", sort=False).head(args.max_hot)
            hot = hot[["page_addr", "epoch_idx"]]
            hot_path = out_dir / f"{args.workload}_nonacc_hotlist_th{th}{maxhot_tag}_1ms_{range_tag}.csv"
            hot.to_csv(hot_path, index=False)
            print(f"  th={th}{maxhot_tag}: {len(hot)} hot (page,epoch) pairs -> {hot_path.name}")


if __name__ == "__main__":
    main()
