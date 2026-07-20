"""CLI for direct .bin trace parsing and validation."""

from __future__ import annotations

import argparse
from pathlib import Path
import sys

import numpy as np

try:
    from .binio import decode_if_valid, iter_raw_records, read_header
    from .metrics import (
        build_page_and_bin_dataframes,
        parse_horizon_ticks,
        parse_window_specs,
    )
    from .plots import (
        plot_continuity_vs_intensity,
        plot_page_count_heatmap,
        plot_continuity_sweep,
        plot_heatmap_sweep,
        plot_3d_page_density,
    )
    from .timebase import elapsed_ticks, ticks_to_us
    from .counter_set import run_counter_set_simulation, run_cm_sketch_simulation, summarise_hot_pages
except ImportError:
    from binio import decode_if_valid, iter_raw_records, read_header
    from metrics import (
        build_page_and_bin_dataframes,
        parse_horizon_ticks,
        parse_window_specs,
    )
    from plots import (
        plot_continuity_vs_intensity,
        plot_page_count_heatmap,
        plot_continuity_sweep,
        plot_heatmap_sweep,
        plot_3d_page_density,
    )
    from timebase import elapsed_ticks, ticks_to_us
    from counter_set import run_counter_set_simulation, run_cm_sketch_simulation, summarise_hot_pages


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="TRAC .bin parser utilities")
    subparsers = parser.add_subparsers(dest="command", required=True)

    validate = subparsers.add_parser(
        "validate",
        help="Parse .bin directly and print header + record validation summary.",
    )
    validate.add_argument("input_bin", type=Path, help="Path to input .bin file")
    validate.add_argument(
        "--freq-mhz",
        type=float,
        default=400.0,
        help="Timestamp frequency in MHz for elapsed microseconds (default: 400).",
    )
    validate.add_argument(
        "--chunk-size",
        type=int,
        default=1024 * 1024,
        help="Read chunk size in bytes (default: 1048576).",
    )
    validate.add_argument(
        "--preview-n",
        type=int,
        default=5,
        help="Number of decoded valid records to preview (default: 5).",
    )

    pages = subparsers.add_parser(
        "pages",
        help="Compute 4KB page-level continuity/intensity metrics.",
    )
    pages.add_argument("input_bin", type=Path, help="Path to input .bin file")
    pages.add_argument(
        "--freq-mhz",
        type=float,
        default=400.0,
        help="Timestamp frequency in MHz for us/ms window parsing (default: 400).",
    )
    pages.add_argument(
        "--windows",
        type=str,
        default="10us,100us,1ms,10ms",
        help="Comma-separated windows (e.g. 10us,100us,1ms,10ms or 1000t).",
    )
    pages.add_argument(
        "--chunk-size",
        type=int,
        default=1024 * 1024,
        help="Read chunk size in bytes (default: 1048576).",
    )
    pages.add_argument(
        "--output",
        type=Path,
        default=Path("outputs/pages.csv"),
        help="Output CSV path (default: outputs/pages.csv).",
    )
    pages.add_argument(
        "--page-bins-output",
        type=Path,
        default=Path("outputs/page_bins.csv"),
        help="Output page-bin CSV path (default: outputs/page_bins.csv).",
    )
    pages.add_argument(
        "--start-time",
        type=str,
        default=None,
        help=(
            "Start of analysis window, relative to first valid record "
            "(e.g. '10ms', '500us', '400000t'). Default: trace start."
        ),
    )
    pages.add_argument(
        "--end-time",
        type=str,
        default=None,
        help=(
            "End of analysis window, relative to first valid record "
            "(e.g. '200ms', '1s'). Default: trace end."
        ),
    )
    pages.add_argument(
        "--horizon",
        type=str,
        default="10ms",
        help="Future horizon for trigger-based reuse/payback (default: 10ms).",
    )
    pages.add_argument(
        "--migration-cost",
        type=float,
        default=64.0,
        help="Migration cost in same units as delta-access-cost (default: 64).",
    )
    pages.add_argument(
        "--delta-access-cost",
        type=float,
        default=1.0,
        help="Benefit per future access after migration (default: 1).",
    )
    pages.add_argument(
        "--class-window",
        type=str,
        default="1ms",
        help="Preferred window label for visualization/class views (default: 1ms).",
    )
    pages.add_argument(
        "--no-3d",
        dest="no_3d",
        action="store_true",
        default=False,
        help="Skip all 3D page density plots (faster runs).",
    )
    pages.add_argument(
        "--th-sweep",
        type=str,
        default=None,
        help=(
            "Comma-separated threshold values to sweep for LFU and CM-sketch 3D plots "
            "(e.g. '6,12,24,48'). For each value, generates "
            "{workload}_{scheme}_th{th}_{epoch}.png using the 'all' colour scale."
        ),
    )
    pages.add_argument(
        "--density-3d-dir",
        dest="density_3d_dir",
        type=Path,
        default=Path("outputs"),
        help=(
            "Output directory for 3D density plots. "
            "Plots are auto-named {workload}_{scheme}_{epoch}.png "
            "(default: outputs/)."
        ),
    )
    pages.add_argument(
        "--3d-bins",
        dest="density_3d_bins",
        type=int,
        default=40,
        help="Number of bins per axis for 3D density plot (default: 40).",
    )

    # CM-sketch simulation arguments
    pages.add_argument(
        "--cms-width",
        type=int,
        default=4096,
        help="CM-sketch width (counters per row, default: 4096).",
    )
    pages.add_argument(
        "--cms-depth",
        type=int,
        default=4,
        help="CM-sketch depth (number of hash rows, default: 4).",
    )
    pages.add_argument(
        "--cms-hot-th",
        type=int,
        default=6,
        help="CM-sketch hot threshold: frequency estimate >= cms_hot_th triggers detection (default: 6).",
    )
    pages.add_argument(
        "--cms-detail-output",
        type=Path,
        default=Path("outputs/cms_detail.csv"),
        help="Per-event CM-sketch hot detection output CSV (default: outputs/cms_detail.csv).",
    )
    pages.add_argument(
        "--cms-summary-output",
        type=Path,
        default=Path("outputs/cms_summary.csv"),
        help="Per-page CM-sketch hot detection summary CSV (default: outputs/cms_summary.csv).",
    )

    # Counter-set simulation arguments
    pages.add_argument(
        "--cms-mode",
        type=str,
        default="always_on",
        choices=["always_on", "epoch_end"],
        help="CM-sketch detection mode (default: always_on).",
    )
    pages.add_argument(
        "--cs-index-bits",
        type=int,
        default=7,
        help="Index bits for counter set (sets = 2^index_bits, default: 7 → 128 sets).",
    )
    pages.add_argument(
        "--cs-num-way",
        type=int,
        default=8,
        help="Number of ways per set (default: 8).",
    )
    pages.add_argument(
        "--cs-hot-th",
        type=int,
        default=6,
        help="Hot threshold: counter >= hot_th triggers detection (default: 6).",
    )
    pages.add_argument(
        "--cs-detail-output",
        type=Path,
        default=Path("outputs/counter_set_detail.csv"),
        help="Per-event hot detection output CSV (default: outputs/counter_set_detail.csv).",
    )
    pages.add_argument(
        "--cs-summary-output",
        type=Path,
        default=Path("outputs/counter_set_summary.csv"),
        help="Per-page hot detection summary CSV (default: outputs/counter_set_summary.csv).",
    )
    pages.add_argument(
        "--max-hot-per-epoch",
        dest="max_hot_per_epoch",
        type=int,
        default=None,
        help=(
            "Cap hot pages per epoch (default: unlimited). "
            "always_on: first-come-first-served. "
            "epoch_end: top-N by count at flush time. "
            "polling: top-N per poll interval (total cap = N * epoch/polling)."
        ),
    )
    pages.add_argument(
        "--polling",
        type=str,
        default=None,
        help=(
            "Polling interval for hot-page detection within each epoch "
            "(e.g. '1ms', '100us'). When set, counters accumulate within each "
            "polling interval; hot pages (>= threshold) are popped at each poll "
            "boundary. Non-hot entries keep accumulating (LFU) or are reset (CMS). "
            "Epoch boundary does a final poll flush then resets all counters. "
            "Default: None (existing always_on / epoch_end behavior)."
        ),
    )
    pages.add_argument(
        "--downsample-n",
        dest="downsample_n",
        type=int,
        default=1,
        help=(
            "Downsample accesses: only process the i-th access when i %% N == 0. "
            "N=1 (default) processes all accesses; N=2 keeps every other access; "
            "N=4 keeps every 4th access. Epoch/poll boundaries are still determined "
            "by real timestamps regardless of downsampling."
        ),
    )

    return parser


def _run_validate(args: argparse.Namespace) -> int:
    if args.freq_mhz is not None and args.freq_mhz <= 0:
        print(f"Invalid frequency: {args.freq_mhz}", file=sys.stderr)
        return 2

    total_scanned = 0
    valid_records = 0
    read_count = 0
    write_count = 0
    first_timestamp = None
    preview: list[tuple[int, int, int, int, float | None]] = []

    try:
        with args.input_bin.open("rb") as f:
            header = read_header(f)

            for record_low, record_high in iter_raw_records(
                f, chunk_size=args.chunk_size
            ):
                total_scanned += 1
                decoded = decode_if_valid(record_low, record_high)
                if decoded is None:
                    continue

                valid_records += 1
                if decoded.op_type == 0:
                    read_count += 1
                else:
                    write_count += 1

                if first_timestamp is None:
                    first_timestamp = decoded.timestamp

                if len(preview) < args.preview_n:
                    dticks = elapsed_ticks(decoded.timestamp, first_timestamp)
                    dus = ticks_to_us(dticks, args.freq_mhz)
                    preview.append(
                        (
                            decoded.op_type,
                            decoded.address,
                            decoded.timestamp,
                            dticks,
                            dus,
                        )
                    )
    except (OSError, ValueError) as exc:
        print(f"Error: {exc}", file=sys.stderr)
        return 1

    print("Header:")
    print(f"  magic: 0x{header.magic:08x}")
    print(f"  version: {header.version}")
    print(f"  buffer_size: {header.buffer_size}")
    print(f"  written_traces: {header.written_traces}")
    print(f"  dropped_traces: {header.dropped_traces}")
    print("Scan summary:")
    print(f"  total_scanned_records: {total_scanned}")
    print(f"  valid_records: {valid_records}")
    print(f"  read_count: {read_count}")
    print(f"  write_count: {write_count}")

    print(f"First {len(preview)} decoded valid records:")
    if args.freq_mhz is None:
        print("  idx,type,address,timestamp,elapsed_ticks")
    else:
        print("  idx,type,address,timestamp,elapsed_ticks,elapsed_us")

    for idx, (op_type, address, timestamp, dticks, dus) in enumerate(preview):
        op_name = "WRITE" if op_type else "READ"
        if dus is None:
            print(
                f"  {idx},{op_name},0x{address:016x},{timestamp},{dticks}"
            )
        else:
            print(
                f"  {idx},{op_name},0x{address:016x},{timestamp},"
                f"{dticks},{dus:.6f}"
            )

    return 0


_MODE_ABBR = {"always_on": "ao", "epoch_end": "ee"}


def _run_pages(args: argparse.Namespace) -> int:
    if args.freq_mhz is not None and args.freq_mhz <= 0:
        print(f"Invalid frequency: {args.freq_mhz}", file=sys.stderr)
        return 2

    try:
        windows = [w.strip() for w in args.windows.split(",")]
        window_specs = parse_window_specs(windows=windows, freq_mhz=args.freq_mhz)
        horizon_ticks = parse_horizon_ticks(args.horizon, args.freq_mhz)
        _st = parse_horizon_ticks(args.start_time, args.freq_mhz) if args.start_time else 0
        start_ticks = _st if _st > 0 else None
        end_ticks   = parse_horizon_ticks(args.end_time,   args.freq_mhz) if args.end_time   else None
        if start_ticks is not None and end_ticks is not None and end_ticks <= start_ticks:
            print("--end-time must be greater than --start-time", file=sys.stderr)
            return 2
        page_df, bin_df = build_page_and_bin_dataframes(
            input_bin=args.input_bin,
            window_specs=window_specs,
            horizon_ticks=horizon_ticks,
            migration_cost=args.migration_cost,
            delta_access_cost=args.delta_access_cost,
            chunk_size=args.chunk_size,
            start_ticks=start_ticks,
            end_ticks=end_ticks,
            downsample_n=args.downsample_n,
        )
    except (OSError, ValueError) as exc:
        print(f"Error: {exc}", file=sys.stderr)
        return 1

    args.density_3d_dir.mkdir(parents=True, exist_ok=True)

    workload = args.input_bin.stem
    epoch_label = args.class_window
    time_suffix = ""
    time_range_label = ""
    if args.start_time or args.end_time:
        s = args.start_time or "0"
        e = args.end_time or "end"
        time_suffix = f"_{s}-{e}"
        time_range_label = f"{s}-{e}"

    # Compute reference axis/colorbar limits from the full "all" data
    ref_xlim = ref_ylim = ref_vmax = None
    if not page_df.empty:
        g_ref = page_df[page_df["window"] == args.class_window]
        if g_ref.empty:
            min_ticks = page_df["window_ticks"].min()
            g_ref = page_df[page_df["window_ticks"] == min_ticks]
        if not g_ref.empty:
            x_ref = g_ref["duty_cycle"].to_numpy(dtype=float)
            y_ref = g_ref["total_accesses"].to_numpy(dtype=float)
            ref_xlim = (float(x_ref.min()), float(x_ref.max()))
            ref_ylim = (float(y_ref.min()), float(y_ref.max()))
            counts_ref, _, _ = np.histogram2d(x_ref, y_ref, bins=(40, 40))
            ref_vmax = float(counts_ref.max()) if counts_ref.max() > 0 else 1.0

    plot_dir = args.density_3d_dir / workload
    plot_dir.mkdir(parents=True, exist_ok=True)

    def _plot_pair(hot_set, suffix, label, hot_list_count=None):
        """Generate continuity plot for a given page subset."""
        c_path = plot_dir / f"{workload}_continuity_{suffix}_{epoch_label}{time_suffix}.png"
        plot_continuity_vs_intensity(
            page_df, c_path, args.class_window,
            hot_page_set=hot_set, scheme_label=label, time_range_label=time_range_label,
            xlim=ref_xlim, ylim=ref_ylim, hot_list_count=hot_list_count,
        )
        print(f"Wrote {c_path}")

    # "all" variant
    _plot_pair(None, "all", "all")

    # Save per-page summary CSV for "all" (address, active_time_us, access_count)
    if not page_df.empty:
        g_all = page_df[page_df["window"] == args.class_window]
        if g_all.empty:
            min_ticks = page_df["window_ticks"].min()
            g_all = page_df[page_df["window_ticks"] == min_ticks]
        if not g_all.empty:
            all_csv = g_all[["page_number", "active_span", "total_accesses", "w90_ticks"]].copy()
            all_csv["active_time_us"] = (all_csv["active_span"] + 1) / args.freq_mhz
            all_csv["w90_us"] = (all_csv["w90_ticks"] + 1) / args.freq_mhz
            all_csv = all_csv.rename(columns={"page_number": "page_addr", "total_accesses": "access_count"})
            all_csv = all_csv[["page_addr", "active_time_us", "access_count", "w90_us"]]
            all_csv = all_csv.sort_values("access_count", ascending=False).reset_index(drop=True)
            all_csv_path = plot_dir / f"{workload}_all_{epoch_label}{time_suffix}.csv"
            all_csv.to_csv(all_csv_path, index=False)
            print(f"Wrote {all_csv_path}")

    # Epoch ticks for counter simulations: always parsed directly from --class-window,
    # independent of --windows so continuity bins and epoch can differ.
    epoch_ticks = parse_window_specs([args.class_window], args.freq_mhz)[0].ticks
    polling_ticks = parse_window_specs([args.polling], args.freq_mhz)[0].ticks if args.polling else None

    cms_abbr = _MODE_ABBR[args.cms_mode]

    # 3D density: "all" only (scheme plots come from sweep)
    shared_z_max = None
    if not args.no_3d:
        out_path = plot_dir / f"{workload}_all_{epoch_label}{time_suffix}.png"
        shared_z_max = plot_3d_page_density(
            page_df, out_path, args.class_window, args.density_3d_bins,
            hot_page_set=None, scheme_label="all", z_max=None,
            time_range_label=time_range_label,
        )
        print(f"Wrote {out_path}  (all pages)")

    # Threshold sweep (simulations in parallel, plots sequential)
    if args.th_sweep:
        from concurrent.futures import ThreadPoolExecutor, as_completed

        try:
            thresholds = [int(t.strip()) for t in args.th_sweep.split(",") if t.strip()]
        except ValueError as exc:
            print(f"Invalid --th-sweep value: {exc}", file=sys.stderr)
            return 2

        jobs = [(scheme, th) for th in thresholds for scheme in ("lfu_ao", "lfu_ee", "cms")]
        print(f"Threshold sweep {thresholds}: launching {len(jobs)} simulation jobs in parallel...")

        def _sim_job(scheme_th: tuple) -> tuple:
            scheme, th = scheme_th
            if scheme == "lfu_ao":
                df = run_counter_set_simulation(
                    input_bin=args.input_bin,
                    epoch_ticks=epoch_ticks,
                    index_bits=args.cs_index_bits,
                    num_way=args.cs_num_way,
                    hot_th=th,
                    chunk_size=args.chunk_size,
                    start_ticks=start_ticks,
                    end_ticks=end_ticks,
                    mode="always_on",
                    max_hot_per_epoch=args.max_hot_per_epoch,
                    polling_ticks=None,  # always_on: immediate detect, no polling
                    downsample_n=args.downsample_n,
                )
            elif scheme == "lfu_ee":
                df = run_counter_set_simulation(
                    input_bin=args.input_bin,
                    epoch_ticks=epoch_ticks,
                    index_bits=args.cs_index_bits,
                    num_way=args.cs_num_way,
                    hot_th=th,
                    chunk_size=args.chunk_size,
                    start_ticks=start_ticks,
                    end_ticks=end_ticks,
                    mode="epoch_end",
                    max_hot_per_epoch=args.max_hot_per_epoch,
                    polling_ticks=None,  # epoch_end uses full-epoch flush, not polling
                    downsample_n=args.downsample_n,
                )
            else:
                df = run_cm_sketch_simulation(
                    input_bin=args.input_bin,
                    epoch_ticks=epoch_ticks,
                    width=args.cms_width,
                    depth=args.cms_depth,
                    hot_th=th,
                    chunk_size=args.chunk_size,
                    start_ticks=start_ticks,
                    end_ticks=end_ticks,
                    mode=args.cms_mode,
                    max_hot_per_epoch=args.max_hot_per_epoch,
                    polling_ticks=polling_ticks,
                    downsample_n=args.downsample_n,
                )
            hot_list_count = len(df)
            pages = set(summarise_hot_pages(df)["page_addr"].tolist())
            return scheme, th, pages, hot_list_count, df

        sweep_results: dict[tuple, tuple] = {}
        with ThreadPoolExecutor(max_workers=len(jobs)) as pool:
            futures = {pool.submit(_sim_job, job): job for job in jobs}
            for fut in as_completed(futures):
                scheme, th, pages, hot_list_count, detail_df = fut.result()
                sweep_results[(scheme, th)] = (pages, hot_list_count, detail_df)
                print(f"  done: {scheme} th={th} → {len(pages)} hot pages ({hot_list_count} list entries)")

        for scheme in ("lfu_ao", "lfu_ee", "cms"):
            sweep_items = []
            for th in thresholds:
                pages, hot_list_count, detail_df = sweep_results[(scheme, th)]
                if scheme == "lfu_ao":
                    lbl = f"lfu-ao th={th}"
                    suf = f"lfu_ao_th{th}"
                elif scheme == "lfu_ee":
                    lbl = f"lfu-ee th={th}"
                    suf = f"lfu_ee_th{th}"
                else:
                    lbl = f"cms-{cms_abbr} th={th}"
                    suf = f"cms_{cms_abbr}_th{th}"
                # Save detection-order address list to CSV
                if not detail_df.empty:
                    csv_path = plot_dir / f"{workload}_hotlist_{suf}_{epoch_label}{time_suffix}.csv"
                    epoch_offset = int(start_ticks // epoch_ticks) if start_ticks else 0
                    out_df = detail_df[["page_addr", "epoch_idx"]].copy()
                    out_df["epoch_idx"] = out_df["epoch_idx"] + epoch_offset
                    out_df.to_csv(csv_path, index=False)
                    print(f"Wrote {csv_path}")
                sweep_items.append({
                    "label": lbl, "suf": suf,
                    "hot_page_set": pages, "hot_list_count": hot_list_count,
                })

            scheme_key = scheme if scheme != "cms" else f"cms_{cms_abbr}"
            c_path = plot_dir / f"{workload}_continuity_{scheme_key}_sweep_{epoch_label}{time_suffix}.png"
            plot_continuity_sweep(
                page_df, c_path, args.class_window, sweep_items,
                xlim=ref_xlim, ylim=ref_ylim, time_range_label=time_range_label,
            )
            print(f"Wrote {c_path}")

            if not args.no_3d:
                for item in sweep_items:
                    out_path = plot_dir / f"{workload}_{item['suf']}_{epoch_label}{time_suffix}.png"
                    plot_3d_page_density(
                        page_df, out_path, args.class_window, args.density_3d_bins,
                        hot_page_set=item["hot_page_set"], scheme_label=item["label"],
                        z_max=shared_z_max, time_range_label=time_range_label,
                    )
                    print(f"Wrote {out_path}  ({len(item['hot_page_set'])} pages)")

    return 0


def main() -> int:
    parser = _build_parser()
    args = parser.parse_args()

    if args.command == "validate":
        return _run_validate(args)
    if args.command == "pages":
        return _run_pages(args)

    print(f"Unknown command: {args.command}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
