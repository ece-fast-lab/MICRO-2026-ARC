"""4KB page mapping and page-level event aggregation."""

from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path
from typing import Dict, Optional

try:
    from .binio import decode_if_valid, iter_raw_records, read_header
except ImportError:
    from binio import decode_if_valid, iter_raw_records, read_header


PAGE_SHIFT = 12


@dataclass
class PageEventAccumulator:
    total_accesses: int = 0
    first_ts: Optional[int] = None
    last_ts: Optional[int] = None
    read_count: int = 0
    write_count: int = 0
    # window_label -> (bin_index -> count)
    window_bin_counts: Dict[str, Dict[int, int]] = field(default_factory=dict)
    # window_label -> (bin_index -> first/last timestamp within that bin)
    window_bin_first_ts: Dict[str, Dict[int, int]] = field(default_factory=dict)
    window_bin_last_ts: Dict[str, Dict[int, int]] = field(default_factory=dict)


@dataclass(frozen=True)
class TraceScanState:
    first_valid_ts: int
    last_valid_ts: int
    total_scanned_records: int
    valid_records: int


def page_number_from_address(address: int) -> int:
    return address >> PAGE_SHIFT


def scan_pages_with_windows(
    input_bin: Path,
    window_ticks_by_label: dict[str, int],
    chunk_size: int = 1024 * 1024,
    start_ticks: Optional[int] = None,
    end_ticks: Optional[int] = None,
    downsample_n: int = 1,
) -> tuple[dict[int, PageEventAccumulator], TraceScanState]:
    pages: dict[int, PageEventAccumulator] = {}
    total_scanned = 0
    valid_records = 0
    raw_first_ts: Optional[int] = None   # absolute trace start, used for range filtering
    first_valid_ts: Optional[int] = None  # first ts inside the filter window (bin origin)
    last_valid_ts: Optional[int] = None

    with input_bin.open("rb") as f:
        read_header(f)
        for record_low, record_high in iter_raw_records(f, chunk_size=chunk_size):
            total_scanned += 1
            decoded = decode_if_valid(record_low, record_high)
            if decoded is None:
                continue

            ts = decoded.timestamp
            if raw_first_ts is None:
                raw_first_ts = ts

            abs_elapsed = ts - raw_first_ts
            if start_ticks is not None and abs_elapsed < start_ticks:
                continue
            if end_ticks is not None and abs_elapsed > end_ticks:
                break

            valid_records += 1
            if first_valid_ts is None:
                first_valid_ts = ts
            last_valid_ts = ts

            if downsample_n > 1 and valid_records % downsample_n != 0:
                continue

            page_num = page_number_from_address(decoded.address)
            page_acc = pages.get(page_num)
            if page_acc is None:
                page_acc = PageEventAccumulator()
                page_acc.window_bin_counts = {
                    label: {} for label in window_ticks_by_label
                }
                page_acc.window_bin_first_ts = {
                    label: {} for label in window_ticks_by_label
                }
                page_acc.window_bin_last_ts = {
                    label: {} for label in window_ticks_by_label
                }
                pages[page_num] = page_acc

            page_acc.total_accesses += 1
            if page_acc.first_ts is None:
                page_acc.first_ts = ts
            page_acc.last_ts = ts
            if decoded.op_type == 0:
                page_acc.read_count += 1
            else:
                page_acc.write_count += 1

            elapsed = ts - first_valid_ts
            for label, window_ticks in window_ticks_by_label.items():
                bin_idx = elapsed // window_ticks
                bins = page_acc.window_bin_counts[label]
                bins[bin_idx] = bins.get(bin_idx, 0) + 1
                first_ts_bins = page_acc.window_bin_first_ts[label]
                if bin_idx not in first_ts_bins:
                    first_ts_bins[bin_idx] = ts
                page_acc.window_bin_last_ts[label][bin_idx] = ts

    if first_valid_ts is None or last_valid_ts is None:
        raise ValueError("No valid records found in input trace.")

    return pages, TraceScanState(
        first_valid_ts=first_valid_ts,
        last_valid_ts=last_valid_ts,
        total_scanned_records=total_scanned,
        valid_records=valid_records,
    )
