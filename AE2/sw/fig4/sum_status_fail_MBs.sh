#!/usr/bin/env bash
set -euo pipefail

# debug_monitor.log -> <input>.txt (CSV)
#
# Output columns:
# t_sec,
# pgpromote_success,
# pgmigrate_success,
# pgmigrate_fail,
# numa_pages_migrated,
# Total_node0_MB,
# Total_node1_MB,
# pgmigrate_success_per_sec,
# migration_bandwidth_MBps
#
# Notes:
# - t_sec is 1-second resolution from the first "periodic @" timestamp
# - missing seconds are forward-filled with previous values
# - counters are rebased so the first observed value becomes 0
# - rate is computed from pgmigrate_success, not numa_pages_migrated
# - bandwidth assumes 1 page = 4 KB, so:
#     MB/s = pages_per_sec * 4 / 1024
#
# Usage:
#   ./sum_status_fail_MBs.sh debug_monitor.log [debug_monitor.log.txt]
#
# Output:
#   debug_monitor.log.txt

if (( $# < 1 || $# > 2 )); then
  echo "Usage: $0 <debug_monitor.log> [output.txt]" >&2
  exit 2
fi

IN="$1"
OUT="${2:-${IN}.txt}"

[[ -r "$IN" ]] || {
  echo "ERROR: input log is not readable: $IN" >&2
  exit 1
}
[[ "$IN" != "$OUT" ]] || {
  echo "ERROR: input and output paths must differ" >&2
  exit 1
}

python3 - "$IN" "$OUT" <<'PY'
import re
import sys
from datetime import datetime

inp, outp = sys.argv[1], sys.argv[2]

# Header
re_hdr = re.compile(
    r"^\s*===== \[debug\] periodic @ (\d{4}-\d{2}-\d{2}) (\d{2}:\d{2}:\d{2}) =====\s*$"
)

def re_kv(name: str) -> re.Pattern:
    return re.compile(rf"^\s*{re.escape(name)}\s*[:=]?\s*(\d+)\s*$")

re_prom = re_kv("pgpromote_success")
re_mig  = re_kv("pgmigrate_success")
re_fail = re_kv("pgmigrate_fail")
re_numa = re_kv("numa_pages_migrated")

# Process memory table.  numastat uses a generic header when several matching
# processes exist, but appends "for PID ..." when exactly one process matches.
re_proc_table = re.compile(
    r"^\s*Per-node process memory usage \(in MBs\)(?:\s+for PID\b.*)?\s*$",
    re.IGNORECASE,
)
re_total_row  = re.compile(r"^\s*Total\b", re.IGNORECASE)

samples = []   # list of (datetime, dict)
cur_dt = None
cur = {
    "pgpromote": None,
    "pgmigrate": None,
    "pgmigrate_fail": None,
    "numa": None,
    "n0": None,
    "n1": None,
}
in_proc_table = False

def commit():
    global cur_dt, cur
    if cur_dt is None:
        return
    samples.append((cur_dt, cur.copy()))

with open(inp, "r", encoding="utf-8", errors="replace") as f:
    for raw_line in f:
        line = raw_line.rstrip("\n").rstrip("\r")

        m = re_hdr.match(line)
        if m:
            commit()
            cur_dt = datetime.strptime(
                m.group(1) + " " + m.group(2),
                "%Y-%m-%d %H:%M:%S"
            )
            cur = {
                "pgpromote": None,
                "pgmigrate": None,
                "pgmigrate_fail": None,
                "numa": None,
                "n0": None,
                "n1": None,
            }
            in_proc_table = False
            continue

        if re_proc_table.match(line):
            in_proc_table = True
            continue

        if in_proc_table and re_total_row.match(line):
            nums = [int(x) for x in re.findall(r"\d+", line)]
            # Expect: Total <Node0> <Node1> <Total>
            # Keep only Node0 and Node1
            if len(nums) >= 2:
                cur["n0"] = nums[0]
                cur["n1"] = nums[1]
            in_proc_table = False
            continue

        m = re_prom.match(line)
        if m:
            cur["pgpromote"] = int(m.group(1))
            continue

        m = re_mig.match(line)
        if m:
            cur["pgmigrate"] = int(m.group(1))
            continue

        m = re_fail.match(line)
        if m:
            cur["pgmigrate_fail"] = int(m.group(1))
            continue

        m = re_numa.match(line)
        if m:
            cur["numa"] = int(m.group(1))
            continue

commit()

if not samples:
    raise SystemExit(
        "No periodic blocks found. Expected lines like:\n"
        "===== [debug] periodic @ YYYY-MM-DD HH:MM:SS ====="
    )

# The monitor writes vmstat before numastat.  A final block may therefore be
# incomplete after the workload exits, but the first block must contain every
# field needed to establish the counter baselines and memory series.
required_first = (
    "pgpromote",
    "pgmigrate",
    "pgmigrate_fail",
    "numa",
    "n0",
    "n1",
)
missing_first = [name for name in required_first if samples[0][1][name] is None]
if missing_first:
    raise SystemExit(
        "First periodic block is incomplete; missing: "
        + ", ".join(missing_first)
        + ". Verify that /proc/vmstat and `numastat -c base` were logged."
    )

# Build time-indexed sample map
base_dt = samples[0][0]
sec_to_vals = {}
max_sec = 0

for dt, d in samples:
    t = int((dt - base_dt).total_seconds())
    if t < 0:
        t = 0
    sec_to_vals[t] = d
    if t > max_sec:
        max_sec = t

# Last observed absolute values
last_abs = {
    "pgpromote": None,
    "pgmigrate": None,
    "pgmigrate_fail": None,
    "numa": None,
    "n0": None,
    "n1": None,
}

# Baselines for rebasing counters to 0
base_prom = None
base_mig  = None
base_fail = None
base_numa = None

# Forward-filled memory values
last_out_n0 = ""
last_out_n1 = ""

# ------------------------------------------------------------
# Build per-second slope from pgmigrate_success
# ------------------------------------------------------------
# Example:
#   sample at t=11 => pgmigrate_success=113
#   sample at t=17 => pgmigrate_success=317486
#   delta = 317373 over 6 seconds
#   => seconds 12..17 each get 317373 / 6 pages/sec
# ------------------------------------------------------------
observed_mig = []
raw_mig_base = None

for dt, d in samples:
    if d["pgmigrate"] is None:
        continue
    t = int((dt - base_dt).total_seconds())
    if t < 0:
        t = 0
    if raw_mig_base is None:
        raw_mig_base = d["pgmigrate"]
    rebased_mig = max(0, d["pgmigrate"] - raw_mig_base)
    observed_mig.append((t, rebased_mig))

mig_rate_per_sec = [0.0] * (max_sec + 1)

for i in range(1, len(observed_mig)):
    prev_t, prev_pages = observed_mig[i - 1]
    cur_t, cur_pages = observed_mig[i]

    dt_sec = cur_t - prev_t
    if dt_sec <= 0:
        continue

    delta_pages = cur_pages - prev_pages
    if delta_pages < 0:
        delta_pages = 0

    rate = delta_pages / dt_sec

    for s in range(prev_t + 1, cur_t + 1):
        if 0 <= s <= max_sec:
            mig_rate_per_sec[s] = rate

def fmt_float(x: float) -> str:
    s = f"{x:.6f}"
    s = s.rstrip("0").rstrip(".")
    return s if s else "0"

with open(outp, "w", encoding="utf-8") as out:
    out.write(
        "t_sec,pgpromote_success,pgmigrate_success,pgmigrate_fail,"
        "numa_pages_migrated,Total_node0_MB,Total_node1_MB,"
        "pgmigrate_success_per_sec,migration_bandwidth_MBps\n"
    )

    for t in range(0, max_sec + 1):
        if t in sec_to_vals:
            d = sec_to_vals[t]
            for k in last_abs.keys():
                if d.get(k) is not None:
                    last_abs[k] = d[k]

        if base_prom is None and last_abs["pgpromote"] is not None:
            base_prom = last_abs["pgpromote"]
        if base_mig is None and last_abs["pgmigrate"] is not None:
            base_mig = last_abs["pgmigrate"]
        if base_fail is None and last_abs["pgmigrate_fail"] is not None:
            base_fail = last_abs["pgmigrate_fail"]
        if base_numa is None and last_abs["numa"] is not None:
            base_numa = last_abs["numa"]

        prom_out = 0 if (base_prom is None or last_abs["pgpromote"] is None) else max(0, last_abs["pgpromote"] - base_prom)
        mig_out  = 0 if (base_mig  is None or last_abs["pgmigrate"] is None) else max(0, last_abs["pgmigrate"] - base_mig)
        fail_out = 0 if (base_fail is None or last_abs["pgmigrate_fail"] is None) else max(0, last_abs["pgmigrate_fail"] - base_fail)
        numa_out = 0 if (base_numa is None or last_abs["numa"] is None) else max(0, last_abs["numa"] - base_numa)

        if last_abs["n0"] is not None:
            last_out_n0 = str(last_abs["n0"])
        if last_abs["n1"] is not None:
            last_out_n1 = str(last_abs["n1"])

        pages_per_sec = mig_rate_per_sec[t]
        bandwidth_mbps = pages_per_sec * 4.0 / 1024.0

        out.write(
            f"{t},{prom_out},{mig_out},{fail_out},{numa_out},"
            f"{last_out_n0},{last_out_n1},"
            f"{fmt_float(pages_per_sec)},{fmt_float(bandwidth_mbps)}\n"
        )
PY

echo "[done] wrote: $OUT" >&2
