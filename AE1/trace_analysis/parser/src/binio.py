"""Binary trace parsing utilities for TRAC .bin files."""

from __future__ import annotations

from dataclasses import dataclass
import struct
from typing import BinaryIO, Iterator, Optional


MAGIC_TRAC = 0x54524143
HEADER_STRUCT = struct.Struct("<IIQQQ")
RECORD_STRUCT = struct.Struct("<QQ")
DEFAULT_CHUNK_SIZE = 1024 * 1024  # Match C converter chunking.

VALID_BIT = 63
OP_TYPE_BIT = 62
ADDRESS_MASK_52BIT = 0x000F_FFFF_FFFF_FFFF


@dataclass(frozen=True)
class TraceFileHeader:
    magic: int
    version: int
    buffer_size: int
    written_traces: int
    dropped_traces: int


@dataclass(frozen=True)
class DecodedRecord:
    op_type: int  # 0 = READ, 1 = WRITE
    address: int  # 52-bit address
    timestamp: int


@dataclass(frozen=True)
class ValidRecordWithElapsed:
    op_type: int
    address: int
    timestamp: int
    elapsed_ticks: int
    elapsed_us: Optional[float]


@dataclass(frozen=True)
class ValidationSummary:
    header: TraceFileHeader
    total_scanned_records: int
    valid_records: int
    read_count: int
    write_count: int
    first_valid_records: list[ValidRecordWithElapsed]


def read_header(stream: BinaryIO) -> TraceFileHeader:
    raw = stream.read(HEADER_STRUCT.size)
    if len(raw) != HEADER_STRUCT.size:
        raise ValueError("Failed to read complete 32-byte trace header.")

    header = TraceFileHeader(*HEADER_STRUCT.unpack(raw))
    if header.magic != MAGIC_TRAC:
        raise ValueError(
            "Invalid file format. Expected magic number 0x54524143 (TRAC)."
        )
    return header


def iter_raw_records(
    stream: BinaryIO, chunk_size: int = DEFAULT_CHUNK_SIZE
) -> Iterator[tuple[int, int]]:
    """Yield raw 16-byte records.

    Trailing bytes that do not form a full 16-byte record are ignored, matching
    the C converter's `num_records = bytes_read / 16` behavior.
    """
    while True:
        chunk = stream.read(chunk_size)
        if not chunk:
            return

        num_records = len(chunk) // RECORD_STRUCT.size
        usable = num_records * RECORD_STRUCT.size
        for offset in range(0, usable, RECORD_STRUCT.size):
            yield RECORD_STRUCT.unpack_from(chunk, offset)


def decode_if_valid(record_low: int, record_high: int) -> Optional[DecodedRecord]:
    valid = (record_low >> VALID_BIT) & 0x1
    if not valid:
        return None

    op_type = (record_low >> OP_TYPE_BIT) & 0x1
    address = record_low & ADDRESS_MASK_52BIT
    timestamp = record_high
    return DecodedRecord(op_type=op_type, address=address, timestamp=timestamp)

