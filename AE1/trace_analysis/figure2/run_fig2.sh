#!/usr/bin/env bash
# Figure 2 — per-page hotness distribution (gapbs_pr_twitter, 1ms epoch, 10-11ms).
#
#   fig2a.png  = all pages
#   fig2b.png  = LFU (always-on) hot pages, th=32
#   fig2c.png  = CMS (epoch-end) hot pages, th=32
#
# figure_page_dist.py emits ONLY these three panels — no byproducts.
# Reads the bundled CSVs in ../traces/ — no trace re-parse, no outputs/ needed.
# Run from anywhere:  bash MICRO-2026-ARC/AE1/trace_analysis/figure2/run_fig2.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"     # .../AE1/trace_analysis/figure2
PY="${PY:-python3}"

WORKLOAD="gapbs_pr_twitter_t8_n10000000"
SUFFIX="1ms_10ms-11ms"

# The plot script reads the bundled .csv.gz directly — nothing to unpack.
TRACES_DIR="${HERE}/../traces/${WORKLOAD}"
OUTPUTS_DIR="${TRACES_DIR}"
NONACC_DIR="${TRACES_DIR}"

echo "[fig2] generating page-distribution panels"
"${PY}" "${HERE}/figure_page_dist.py" \
    --outputs-dir "${OUTPUTS_DIR}" \
    --nonacc-dir  "${NONACC_DIR}" \
    --workload    "${WORKLOAD}" \
    --start-ms 10 --end-ms 11 \
    --single-th 32 \
    --max-hot 256 \
    --x-max 128 \
    --out-dir "${HERE}"

# Rename to deterministic paper names (no raw files left behind).
mv -f "${HERE}/${WORKLOAD}_cum_all_${SUFFIX}.png"                 "${HERE}/generated_fig2a.png"
mv -f "${HERE}/${WORKLOAD}_cum_single_lfu_ao_th32_${SUFFIX}.png"  "${HERE}/generated_fig2b.png"
mv -f "${HERE}/${WORKLOAD}_cum_single_cms_ee_th32_${SUFFIX}.png"  "${HERE}/generated_fig2c.png"

echo "[fig2] wrote:"
echo "       generated_fig2a.png  (all pages)"
echo "       generated_fig2b.png  (LFU always-on, th=32)"
echo "       generated_fig2c.png  (CMS epoch-end, th=32)"
