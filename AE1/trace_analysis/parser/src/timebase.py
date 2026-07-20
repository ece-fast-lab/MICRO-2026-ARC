"""Timebase helpers for tick and microsecond conversions."""

from __future__ import annotations

from typing import Optional


def elapsed_ticks(timestamp: int, first_timestamp: int) -> int:
    return timestamp - first_timestamp


def ticks_to_us(ticks: int, freq_mhz: Optional[float]) -> Optional[float]:
    if freq_mhz is None:
        return None
    return float(ticks) / float(freq_mhz)

