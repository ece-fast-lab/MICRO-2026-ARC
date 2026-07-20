#!/usr/bin/env bash
# regenerate.sh — rebuild traces/*.csv.gz from the raw .bin memory traces.
#
# This is the FULL-provenance path for artifact evaluation: it re-derives every
# bundled input CSV directly from the raw traces, so a reviewer can reproduce the
# figures end-to-end (raw trace -> CSV -> figure) rather than trusting the shipped
# CSVs. The figure runners (run_figN.sh) then consume the regenerated traces/.
#
# The scanners stop at the analysis window, so this does NOT read the whole
# multi-GB trace:
#   - fig2/5 inputs need only the first 11 ms  (seconds)
#   - fig7 inputs need the first 1000 ms        (minutes per trace)
#
# Usage:
#   bash MICRO-2026-ARC/AE1/trace_analysis/regenerate.sh [--traces-root DIR] [--skip-fig7]
#
#   --traces-root DIR   root holding gapbs/ and spec/ .bin files
#                       (default: /fast-lab-share/cxl_traces/traces)
#   --skip-fig7         only regenerate the cheap fig2/5 inputs (skip the slow
#                       1000 ms all-CSV pass)
#
# The trace parser is vendored under parser/ (src/ + pdf_parser/), so this script
# is self-contained and needs no external checkout. Set PARSER_ROOT to point at a
# different parser tree only for development.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"     # .../AE1/trace_analysis
ROOT="${PARSER_ROOT:-${HERE}/parser}"                     # vendored parser tree
PY="${PY:-python3}"
DEST="${HERE}/traces"

TRACES_ROOT="/fast-lab-share/cxl_traces/traces"
SKIP_FIG7=0
while [ $# -gt 0 ]; do
  case "$1" in
    --traces-root) TRACES_ROOT="$2"; shift 2 ;;
    --skip-fig7)   SKIP_FIG7=1; shift ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

PR="gapbs_pr_twitter_t8_n10000000"
BC="gapbs_bc_twitter_t8_n10000000"
GCC="spec_502_gcc_r_c8"
declare -A BIN=(
  [$PR]="gapbs/${PR}.bin"
  [$BC]="gapbs/${BC}.bin"
  [$GCC]="spec/${GCC}.bin"
)

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

gz() { gzip -9 -c "$1" > "$2"; echo "  wrote $(basename "$2")"; }

# drop_col <csv> <column-name>  -> CSV on stdout without that column (by header name)
drop_col() {
  awk -F, -v want="$2" '
    NR==1 { for (i=1; i<=NF; i++) if ($i == want) c = i }
    { out = ""; for (i=1; i<=NF; i++) { if (i == c) continue;
        out = out (out == "" ? "" : ",") $i } print out }' "$1"
}

# ---------------------------------------------------------------------------
# fig7 inputs: {workload}_all_1ms_0ms-1000ms.csv  (cli.py pages, first 1000 ms)
# ---------------------------------------------------------------------------
if [ "${SKIP_FIG7}" -eq 0 ]; then
  for wl in "$GCC" "$BC" "$PR"; do
    trace="${TRACES_ROOT}/${BIN[$wl]}"
    echo "[fig7] ${wl}: parsing 0-1000 ms from $(basename "$trace") ..."
    ( cd "${ROOT}" && "${PY}" -m src.cli pages "$trace" \
        --class-window 1ms --windows 1ms \
        --start-time 0ms --end-time 1000ms \
        --no-3d --density-3d-dir "${WORK}/cli" )
    mkdir -p "${DEST}/${wl}"
    # cli.py also emits w90_us, which fig7 never reads — drop it before bundling.
    drop_col "${WORK}/cli/${wl}/${wl}_all_1ms_0ms-1000ms.csv" w90_us \
      | gzip -9 -c > "${DEST}/${wl}/${wl}_all_1ms_0ms-1000ms.csv.gz"
    echo "  wrote ${wl}_all_1ms_0ms-1000ms.csv.gz (w90_us dropped)"
  done
fi

# ---------------------------------------------------------------------------
# fig2/5 inputs: gapbs_pr nonacc, 10-11 ms  (gen_nonacc + gen_nonacc_algo)
# ---------------------------------------------------------------------------
trace="${TRACES_ROOT}/${BIN[$PR]}"
mkdir -p "${DEST}/${PR}"

echo "[fig2/5] ${PR}: nonacc_all 10-11 ms ..."
"${PY}" "${ROOT}/pdf_parser/gen_nonacc.py" \
    --trace "$trace" --workload "$PR" \
    --start-ms 10 --end-ms 11 --threshold 32 64 96 --max-hot 256 \
    --out-dir "${WORK}/na"
gz "${WORK}/na/${PR}_nonacc_all_1ms_10ms-11ms.csv" \
   "${DEST}/${PR}/${PR}_nonacc_all_1ms_10ms-11ms.csv.gz"

echo "[fig2/5] ${PR}: lfu_ao / cms hotlists 10-11 ms ..."
"${PY}" "${ROOT}/pdf_parser/gen_nonacc_algo.py" \
    --trace "$trace" --workload "$PR" \
    --start-ms 10 --end-ms 11 --hot-th 32 64 96 --max-hot 256 \
    --out-dir "${WORK}/na"
for th in 32 64 96; do
  gz "${WORK}/na/${PR}_nonacc_hotlist_lfu_ao_th${th}_maxhot256_1ms_10ms-11ms.csv" \
     "${DEST}/${PR}/${PR}_nonacc_hotlist_lfu_ao_th${th}_maxhot256_1ms_10ms-11ms.csv.gz"
  # CMS epoch-end — this is what the paper's CMS panels are drawn from. It is NOT
  # equivalent to always-on: epoch-end re-scans the whole sketch at flush, so
  # collision-inflated entries are flagged too (uncapped on gapbs_pr th=32:
  # 19,982 pages vs 9,844 always-on). gen_nonacc_algo.py also emits cms_ao, but
  # the figures use cms_ee only.
  gz "${WORK}/na/${PR}_nonacc_hotlist_cms_ee_th${th}_maxhot256_1ms_10ms-11ms.csv" \
     "${DEST}/${PR}/${PR}_nonacc_hotlist_cms_ee_th${th}_maxhot256_1ms_10ms-11ms.csv.gz"
done

echo "Done. Regenerated traces/ from raw. Now run the figure scripts:"
echo "  bash ${HERE}/figure2/run_fig2.sh"
echo "  bash ${HERE}/figure5/run_fig5.sh"
echo "  bash ${HERE}/figure7/run_fig7.sh"
