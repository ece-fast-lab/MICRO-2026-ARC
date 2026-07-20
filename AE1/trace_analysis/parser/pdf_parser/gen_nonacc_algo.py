"""
Run lfu_ao (CounterSet always_on) and cms_ee (CMSketch epoch_end) simulations
and save per-epoch hotlist CSVs for use with figure_th_nonacc_algo.

Output to --out-dir:
  {workload}_nonacc_hotlist_lfu_ao_maxhot{N}_1ms_0ms-{M}ms.csv
  {workload}_nonacc_hotlist_cms_ee_maxhot{N}_1ms_0ms-{M}ms.csv
  columns: page_addr, epoch_idx

Usage:
    python pdf_parser/gen_nonacc_algo.py \\
        --trace /fast-lab-share/cxl_traces/traces/gapbs/gapbs_pr_twitter_t8_n10000000.bin \\
        --workload gapbs_pr_twitter_t8_n10000000 \\
        --end-ms 1 10 100 \\
        --max-hot 256 \\
        --hot-th 6 \\
        --out-dir outputs/nonacc/gapbs_pr_twitter_t8_n10000000
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

import pandas as pd

sys.path.insert(0, str(Path(__file__).parent.parent))
from src.counter_set import run_counter_set_simulation, run_cm_sketch_simulation

FREQ_MHZ = 400
EPOCH_US = 1000.0


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--trace", required=True)
    parser.add_argument("--workload", required=True)
    parser.add_argument("--end-ms", type=int, nargs="+", default=[1, 10, 100])
    parser.add_argument("--start-ms", type=int, nargs="+", default=None,
                        help="Start time(s) in ms (paired with --end-ms; default: 0 for all)")
    parser.add_argument("--max-hot", type=int, default=None,
                        help="Max hot pages per epoch (default: unlimited)")
    parser.add_argument("--hot-th", type=int, nargs="+", default=[16, 32, 64, 96],
                        help="Counter threshold(s) for hot detection (default: 16 32 64 96)")
    parser.add_argument("--index-bits", type=int, default=7)
    parser.add_argument("--num-way", type=int, default=8)
    parser.add_argument("--cms-width", type=int, default=4096)
    parser.add_argument("--cms-depth", type=int, default=4)
    parser.add_argument("--freq-mhz", type=float, default=FREQ_MHZ)
    parser.add_argument("--out-dir", default="outputs/nonacc")
    args = parser.parse_args()

    trace = Path(args.trace)
    out_dir = Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)

    epoch_ticks = int(EPOCH_US * args.freq_mhz)
    max_end_ms = max(args.end_ms)
    end_ticks = int(max_end_ms * 1000 * args.freq_mhz)
    max_hot = args.max_hot
    thresholds = args.hot_th

    for th in thresholds:
        # --- LFU-AO ---
        print(f"Running lfu_ao th={th} up to {max_end_ms}ms ...")
        lfu_df = run_counter_set_simulation(
            input_bin=trace,
            epoch_ticks=epoch_ticks,
            index_bits=args.index_bits,
            num_way=args.num_way,
            hot_th=th,
            end_ticks=end_ticks,
            mode="always_on",
            max_hot_per_epoch=max_hot,
        )
        print(f"  lfu_ao th={th}: {len(lfu_df)} hot events across {lfu_df['epoch_idx'].nunique() if not lfu_df.empty else 0} epochs")

        # --- CMS-EE ---
        print(f"Running cms_ee th={th} up to {max_end_ms}ms ...")
        cms_df = run_cm_sketch_simulation(
            input_bin=trace,
            epoch_ticks=epoch_ticks,
            width=args.cms_width,
            depth=args.cms_depth,
            hot_th=th,
            end_ticks=end_ticks,
            mode="epoch_end",
            max_hot_per_epoch=max_hot,
        )
        print(f"  cms_ee th={th}: {len(cms_df)} hot events across {cms_df['epoch_idx'].nunique() if not cms_df.empty else 0} epochs")

        # --- CMS-AO ---
        # Genuinely different from cms_ee: always_on only re-checks a page's sketch
        # estimate when that page is accessed, so collision-inflated entries that
        # epoch_end catches at flush are missed (ao is a subset of ee).
        print(f"Running cms_ao th={th} up to {max_end_ms}ms ...")
        cms_ao_df = run_cm_sketch_simulation(
            input_bin=trace,
            epoch_ticks=epoch_ticks,
            width=args.cms_width,
            depth=args.cms_depth,
            hot_th=th,
            end_ticks=end_ticks,
            mode="always_on",
            max_hot_per_epoch=max_hot,
        )
        print(f"  cms_ao th={th}: {len(cms_ao_df)} hot events across {cms_ao_df['epoch_idx'].nunique() if not cms_ao_df.empty else 0} epochs")

        # Build (start_ms, end_ms) pairs
        maxhot_tag = f"_maxhot{max_hot}" if max_hot is not None else ""
        if args.start_ms is not None:
            if len(args.start_ms) != len(args.end_ms):
                raise ValueError("--start-ms and --end-ms must have the same number of values")
            time_ranges = sorted(zip(args.start_ms, args.end_ms))
        else:
            time_ranges = [(0, e) for e in sorted(args.end_ms)]

        for start_ms, end_ms in time_ranges:
            start_epoch = int(start_ms * 1000 / EPOCH_US)
            end_epoch = int(end_ms * 1000 / EPOCH_US)
            range_tag = f"{start_ms}ms-{end_ms}ms"
            for algo_key, df in [("lfu_ao", lfu_df), ("cms_ee", cms_df), ("cms_ao", cms_ao_df)]:
                sub = df[(df["epoch_idx"] >= start_epoch) & (df["epoch_idx"] < end_epoch)][["page_addr", "epoch_idx"]].copy()
                sub = sub.drop_duplicates().reset_index(drop=True)
                out_path = out_dir / f"{args.workload}_nonacc_hotlist_{algo_key}_th{th}{maxhot_tag}_1ms_{range_tag}.csv"
                sub.to_csv(out_path, index=False)
                print(f"  [{algo_key} th={th}] {range_tag}: {len(sub)} pairs -> {out_path.name}")


if __name__ == "__main__":
    main()
