#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SW_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
ARTIFACT_DIR="$(cd -- "${SW_DIR}/.." && pwd)"
# shellcheck source=../benchmark/ae_reproduction_common.sh
source "${SW_DIR}/benchmark/ae_reproduction_common.sh"

usage() {
    cat <<'EOF'
Usage:
  generate_lobo_configs.sh <gap|spec> [options]

Generate suite-isolated Leave-One-Benchmark-Out Random Forest configurations.

Options:
  --threshold <16|32|64|96>  Threshold data/configuration (default: 16)
  --source <reference|training>
                              Bundled legacy CSV or fresh reviewer histories
                              (default: reference)
  --replace-pretrained        After generation, explicitly replace the five
                              artifact pretrained cfg files with rank_01
  all yes, -y, --yes          Confirm output backup/replacement
  -h, --help                  Show this help

GAP and SPEC are always trained separately. `--source training` requires all
five workload histories below AE4/results/training/th*/<suite>/.
EOF
}

(( $# > 0 )) || { usage >&2; exit 2; }
suite="$1"
shift
case "$suite" in
    gap|gapbs) suite=gap; training_suite=gapbs; keys=(bc_twitter bfs_twitter cc_twitter pr_twitter pr_web) ;;
    spec) training_suite=spec; keys=(502 505 507 527 554) ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; ae_die "suite must be gap or spec" ;;
esac

threshold=16
source_kind=reference
replace_pretrained=0
auto_yes=0
while (( $# > 0 )); do
    case "$1" in
        --threshold)
            (( $# >= 2 )) || ae_die "--threshold requires a value"
            threshold="$2"; shift 2; continue ;;
        --source)
            (( $# >= 2 )) || ae_die "--source requires a value"
            source_kind="$2"; shift 2; continue ;;
        --replace-pretrained) replace_pretrained=1 ;;
        -y|--yes|--all-yes) auto_yes=1 ;;
        all)
            (( $# >= 2 )) && [[ "$2" == yes ]] || ae_die "'all' must be followed by 'yes'"
            auto_yes=1; shift 2; continue ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; ae_die "unknown option: $1" ;;
    esac
    shift
done
case "$threshold" in 16|32|64|96) ;; *) ae_die "threshold must be 16, 32, 64, or 96" ;; esac
case "$source_kind" in reference|training) ;; *) ae_die "source must be reference or training" ;; esac

command -v python3 >/dev/null 2>&1 || ae_die "python3 is required"
python3 -c 'import numpy, matplotlib, sklearn, joblib' >/dev/null 2>&1 || \
    ae_die "NumPy, Matplotlib, scikit-learn, and joblib are required"

if [[ "$source_kind" == reference ]]; then
    input_csv="${SCRIPT_DIR}/reference_trials/th${threshold}/${suite}.csv"
    [[ -r "$input_csv" ]] || ae_die "missing reference trial CSV: $input_csv"
    source_args=(--input-csv "$input_csv")
else
    training_root="${ARTIFACT_DIR}/results/training/th${threshold}/${training_suite}"
    for key in "${keys[@]}"; do
        history="${training_root}/${key}/history.jsonl"
        [[ -s "$history" ]] || ae_die "missing training history for ${key}: $history"
        row_count="$(grep -cve '^[[:space:]]*$' "$history" || true)"
        success_count="$(grep -c '"return_code": 0' "$history" || true)"
        [[ "$row_count" == 20 && "$success_count" == 20 ]] || \
            ae_die "${key} must have exactly 20 successful fresh trials; found rows=${row_count}, successful=${success_count}"
    done
    source_args=(--ml-root "$training_root")
fi

out_dir="${ARTIFACT_DIR}/results/lobo/th${threshold}/${suite}"
if [[ -e "$out_dir" ]]; then
    ae_confirm "$auto_yes" "LOBO output exists; move it to .bakN and regenerate?" || exit 0
    backup_index=0
    while [[ -e "${out_dir}.bak${backup_index}" ]]; do backup_index=$((backup_index + 1)); done
    mv -- "$out_dir" "${out_dir}.bak${backup_index}"
fi

python3 "${SCRIPT_DIR}/leave_one_benchmark_rf_cfg.py" \
    "${source_args[@]}" \
    --suite "$suite" \
    --out-dir "$out_dir"

if (( replace_pretrained == 1 )); then
    ae_confirm "$auto_yes" "Replace the five th${threshold} ${suite} pretrained cfg files with generated rank_01 values?" || {
        printf 'Generated cfgs kept in: %s/generated_cfg\n' "$out_dir"
        exit 0
    }
    destination="${SCRIPT_DIR}/pretrained/th${threshold}/${suite}"
    for key in "${keys[@]}"; do
        generated="${out_dir}/generated_cfg/${key}/rank_01.cfg"
        [[ -s "$generated" ]] || ae_die "missing generated rank_01 cfg: $generated"
        cp -- "$generated" "${destination}/${key}.cfg"
    done
    printf 'Replaced pretrained cfgs under: %s\n' "$destination"
fi

printf 'LOBO output: %s\n' "$out_dir"
