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
  --profile <name>            Read/write an isolated current-system profile
                              below results/retraining/<name> (training only)
  --replace-pretrained        After generation, explicitly replace the five
                              artifact pretrained cfg files with rank_01
  all yes, -y, --yes          Confirm output backup/replacement
  -h, --help                  Show this help

GAP and SPEC are always trained separately. `--source training` requires all
five workload histories in either the legacy training root or the named
results/retraining/<profile>/training root.
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
profile=""
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
        --profile)
            (( $# >= 2 )) || ae_die "--profile requires a value"
            profile="$2"; shift 2; continue ;;
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
[[ -z "$profile" || "$profile" =~ ^[A-Za-z0-9._-]+$ ]] || \
    ae_die "profile may contain only letters, digits, dot, underscore, and dash"
if [[ -n "$profile" && "$source_kind" != training ]]; then
    ae_die "--profile requires --source training"
fi
if [[ -n "$profile" && "$replace_pretrained" == 1 ]]; then
    ae_die "profile generation keeps shipped pretrained cfgs immutable; evaluate the generated model root instead"
fi

command -v python3 >/dev/null 2>&1 || ae_die "python3 is required"
python3 -c 'import numpy, matplotlib, sklearn, joblib' >/dev/null 2>&1 || \
    ae_die "NumPy, Matplotlib, scikit-learn, and joblib are required"

if [[ "$source_kind" == reference ]]; then
    input_csv="${SCRIPT_DIR}/reference_trials/th${threshold}/${suite}.csv"
    [[ -r "$input_csv" ]] || ae_die "missing reference trial CSV: $input_csv"
    source_args=(--input-csv "$input_csv")
else
    if [[ -n "$profile" ]]; then
        training_root="${ARTIFACT_DIR}/results/retraining/${profile}/training/th${threshold}/${training_suite}"
        python3 "${SCRIPT_DIR}/validate_training_histories.py" \
            --root "$training_root" --suite "$training_suite" \
            --threshold "$threshold" --target 20
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
    fi
    source_args=(--ml-root "$training_root")
fi

if [[ -n "$profile" ]]; then
    profile_root="${ARTIFACT_DIR}/results/retraining/${profile}"
    out_dir="${profile_root}/lobo/th${threshold}/${suite}"
else
    out_dir="${ARTIFACT_DIR}/results/lobo/th${threshold}/${suite}"
fi
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

if [[ -n "$profile" ]]; then
    model_parent="${profile_root}/models/th${threshold}"
    destination="${model_parent}/${suite}"
    mkdir -p "$model_parent"
    staged="$(mktemp -d "${model_parent}/.${suite}.tmp.XXXXXX")" || \
        ae_die "cannot create staged profile model directory"
    cleanup_staged() { rm -rf -- "$staged"; }
    trap cleanup_staged EXIT
    for key in "${keys[@]}"; do
        generated="${out_dir}/generated_cfg/${key}/rank_01.cfg"
        [[ -s "$generated" ]] || ae_die "missing generated rank_01 cfg: $generated"
        cp -- "$generated" "${staged}/${key}.cfg"
    done

    git_commit="$(git -C "${ARTIFACT_DIR}" rev-parse HEAD 2>/dev/null || printf unavailable)"
    python_version="$(python3 -c 'import platform; print(platform.python_version())')"
    numpy_version="$(python3 -c 'import numpy; print(numpy.__version__)')"
    sklearn_version="$(python3 -c 'import sklearn; print(sklearn.__version__)')"
    if [[ "$suite" == gap ]]; then
        stage_a_objective=gapbs_average_time_all_10_arithmetic
    else
        stage_a_objective=spec_total_seconds_elapsed
    fi
    {
        printf 'profile=%s\nthreshold=%s\nsuite=%s\n' "$profile" "$threshold" "$suite"
        printf 'source=training\ntraining_root=%s\nlobo_output=%s\n' "$training_root" "$out_dir"
        printf 'generated_at=%s\n' "$(TZ=America/Chicago date --iso-8601=seconds)"
        printf 'hostname=%s\nkernel_release=%s\ngit_commit=%s\n' \
            "$(hostname -s)" "$(uname -r)" "$git_commit"
        printf 'python_version=%s\nnumpy_version=%s\nscikit_learn_version=%s\n' \
            "$python_version" "$numpy_version" "$sklearn_version"
        printf 'stage_a_objective=%s\n' "$stage_a_objective"
        printf 'stage_a_epoch_order=alternating_400000_400001_and_400001_400000\n'
        printf 'stage_a_rows_per_workload=20\n'
        printf 'stage_b_method=suite_isolated_leave_one_benchmark_out_random_forest\n'
        for key in "${keys[@]}"; do
            printf 'history_sha256.%s=%s\n' "$key" \
                "$(sha256sum "${training_root}/${key}/history.jsonl" | awk '{print $1}')"
            printf 'cfg_sha256.%s=%s\n' "$key" \
                "$(sha256sum "${staged}/${key}.cfg" | awk '{print $1}')"
        done
    } > "${staged}/profile_manifest.txt"

    if [[ -e "$destination" ]]; then
        backup_index=0
        while [[ -e "${destination}.bak${backup_index}" ]]; do
            backup_index=$((backup_index + 1))
        done
        mv -- "$destination" "${destination}.bak${backup_index}"
        printf 'Backed up prior model profile: %s\n' "${destination}.bak${backup_index}"
    fi
    mv -- "$staged" "$destination"
    trap - EXIT
    printf 'Generated immutable-input model profile: %s\n' "$destination"
fi

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
if [[ -n "$profile" ]]; then
    printf 'Figure 11 model root: %s\n' "$destination"
fi
