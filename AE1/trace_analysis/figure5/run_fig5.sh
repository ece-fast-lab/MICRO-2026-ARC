#!/usr/bin/env bash
# Figure 5 — per-algo threshold-sweep scatter (gapbs_pr_twitter, 1ms epoch, 10-11ms).
#
#   fig5a.png  = LFU (always-on), threshold sweep 32/64/96  (cum_scatter_b_lfu_ao)
#   fig5b.png  = CMS (epoch-end), threshold sweep 32/64/96  (cum_scatter_b_cms_ee)
#
# The plot script (figure_th_sweep.py) emits ONLY these two panels — no byproducts.
# Reads the bundled CSVs in ../traces/ — no trace re-parse, no outputs/ needed.
# Run from anywhere:  bash MICRO-2026-ARC/AE1/trace_analysis/figure5/run_fig5.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"     # .../AE1/trace_analysis/figure5
PY="${PY:-python3}"

WORKLOAD="gapbs_pr_twitter_t8_n10000000"
SUFFIX="1ms_10ms-11ms"

# The plot script reads the bundled .csv.gz directly — nothing to unpack.
TRACES_DIR="${HERE}/../traces/${WORKLOAD}"
OUTPUTS_DIR="${TRACES_DIR}"
NONACC_DIR="${TRACES_DIR}"

echo "[fig5] generating scatter_b panels"
"${PY}" "${HERE}/figure_th_sweep.py" \
    --outputs-dir "${OUTPUTS_DIR}" \
    --nonacc-dir  "${NONACC_DIR}" \
    --workload    "${WORKLOAD}" \
    --start-ms 10 --end-ms 11 \
    --threshold 32 64 96 \
    --max-hot 256 \
    --x-max 128 \
    --out-dir "${HERE}"

# Rename the two panels to deterministic paper names (no raw files left behind).
mv -f "${HERE}/${WORKLOAD}_cum_scatter_b_lfu_ao_${SUFFIX}.png" "${HERE}/generated_fig5a.png"
mv -f "${HERE}/${WORKLOAD}_cum_scatter_b_cms_ee_${SUFFIX}.png" "${HERE}/generated_fig5b.png"

echo "[fig5] wrote:"
echo "       generated_fig5a.png  (LFU always-on, th sweep 32/64/96)"
echo "       generated_fig5b.png  (CMS epoch-end, th sweep 32/64/96)"
