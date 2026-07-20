#!/usr/bin/env bash
# Figure 7 — access-count vs elapsed-time density heatmap (1ms epoch, 0-1000ms).
#
#   fig7a.png  = spec_502_gcc_r_c8
#   fig7b.png  = gapbs_bc_twitter
#   fig7c.png  = gapbs_pr_twitter
#
# The x-axis range and colorbar are shared across all workloads (frozen as
# constants inside figure_access_dist.py), so only these three CSVs are needed.
# Reads the bundled CSVs in ../traces/ — no trace re-parse, no outputs/ needed.
# Run from anywhere:  bash MICRO-2026-ARC/AE1/trace_analysis/figure7/run_fig7.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"     # .../AE1/trace_analysis/figure7
PY="${PY:-python3}"

EPOCH="1ms_0ms-1000ms"

W_A="spec_502_gcc_r_c8"
W_B="gapbs_bc_twitter_t8_n10000000"
W_C="gapbs_pr_twitter_t8_n10000000"

# The plot script reads the bundled .csv.gz directly — nothing to unpack.
OUTPUTS_DIR="${HERE}/../traces"

echo "[fig7] generating scatter_w100 panels (shared x-axis + norm over all workloads)"
"${PY}" "${HERE}/figure_access_dist.py" \
    --outputs-dir "${OUTPUTS_DIR}" \
    --epoch "${EPOCH}" \
    --render "${W_A}" "${W_B}" "${W_C}" \
    --out-dir "${HERE}"

# Rename to deterministic paper names (no raw files left behind).
mv -f "${HERE}/${W_A}_scatter_w100_${EPOCH}.png" "${HERE}/generated_fig7a.png"
mv -f "${HERE}/${W_B}_scatter_w100_${EPOCH}.png" "${HERE}/generated_fig7b.png"
mv -f "${HERE}/${W_C}_scatter_w100_${EPOCH}.png" "${HERE}/generated_fig7c.png"

echo "[fig7] wrote:"
echo "       generated_fig7a.png  (spec_502_gcc_r_c8)"
echo "       generated_fig7b.png  (gapbs_bc_twitter)"
echo "       generated_fig7c.png  (gapbs_pr_twitter)"
