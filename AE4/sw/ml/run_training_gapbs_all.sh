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
  run_training_gapbs_all.sh [options]

Run the five GAPBS configuration studies sequentially (20 successful complete
invocations per workload), validate all 100 history rows, and generate a
suite-isolated LOBO model profile. This optional workflow never programs a POF
or reboots SPR1.

Options:
  --threshold <16|32|64|96>  CHMU threshold (default: 16)
  --profile <name>           Isolated retraining profile (default: current-system)
  --resume                   Continue existing studies and start missing ones
  --fresh                    Back up every existing study and start all five anew
  --trial-interval-sec <N>   Idle seconds between invocations (default: 30)
  --skip-lobo                Collect and validate histories, but do not run LOBO
  --status                   Print successful-row counts and exit
  --dry-run                  Print the commands without running benchmarks
  all yes, -y, --yes         Accept the long-run confirmations automatically
  -h, --help                 Show this help

If any benchmark or validation step fails, the script stops immediately. Fix
the reported cause and rerun this same command with --resume. Existing studies
are never replaced unless --fresh is explicit.
EOF
}

threshold=16
profile=current-system
mode=guard
auto_yes=0
skip_lobo=0
status_only=0
dry_run=0
trial_interval_sec="${TRAINING_TRIAL_INTERVAL_SEC:-30}"
workload_interval_sec="${TRAINING_WORKLOAD_INTERVAL_SEC:-30}"

while (( $# > 0 )); do
    case "$1" in
        --threshold)
            (( $# >= 2 )) || ae_die "--threshold requires a value"
            threshold="$2"; shift 2; continue ;;
        --profile)
            (( $# >= 2 )) || ae_die "--profile requires a value"
            profile="$2"; shift 2; continue ;;
        --resume)
            [[ "$mode" != fresh ]] || ae_die "--resume and --fresh are mutually exclusive"
            mode=resume ;;
        --fresh)
            [[ "$mode" != resume ]] || ae_die "--resume and --fresh are mutually exclusive"
            mode=fresh ;;
        --trial-interval-sec)
            (( $# >= 2 )) || ae_die "--trial-interval-sec requires a value"
            trial_interval_sec="$2"; shift 2; continue ;;
        --skip-lobo) skip_lobo=1 ;;
        --status) status_only=1 ;;
        --dry-run) dry_run=1 ;;
        -y|--yes|--all-yes) auto_yes=1 ;;
        all)
            (( $# >= 2 )) && [[ "$2" == yes ]] || \
                ae_die "'all' must be followed by 'yes'"
            auto_yes=1; shift 2; continue ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; ae_die "unknown option: $1" ;;
    esac
    shift
done

case "$threshold" in 16|32|64|96) ;; *) ae_die "threshold must be 16, 32, 64, or 96" ;; esac
[[ "$profile" =~ ^[A-Za-z0-9._-]+$ ]] || \
    ae_die "profile may contain only letters, digits, dot, underscore, and dash"
[[ "$trial_interval_sec" =~ ^[0-9]+$ ]] || \
    ae_die "trial interval must be a non-negative integer"
[[ "$workload_interval_sec" =~ ^[0-9]+$ ]] || \
    ae_die "TRAINING_WORKLOAD_INTERVAL_SEC must be a non-negative integer"

workloads=(bc_tw bfs_tw cc_tw pr_tw pr_web)
keys=(bc_twitter bfs_twitter cc_twitter pr_twitter pr_web)
training_root="${ARTIFACT_DIR}/results/retraining/${profile}/training/th${threshold}/gapbs"

print_status() {
    local index history rows successes
    printf 'AE4 GAPBS retraining status\n'
    printf '  profile   : %s\n' "$profile"
    printf '  threshold : %s\n' "$threshold"
    printf '  root      : %s\n' "$training_root"
    for index in "${!keys[@]}"; do
        history="${training_root}/${keys[$index]}/history.jsonl"
        rows=0
        successes=0
        if [[ -s "$history" ]]; then
            rows="$(grep -cve '^[[:space:]]*$' "$history" || true)"
            successes="$(grep -c '"return_code": 0' "$history" || true)"
        fi
        printf '  %-11s rows=%-2s successful=%-2s history=%s\n' \
            "${workloads[$index]}" "$rows" "$successes" "$history"
    done
}

if (( status_only == 1 )); then
    print_status
    exit 0
fi

existing_studies=0
for key in "${keys[@]}"; do
    [[ -e "${training_root}/${key}" ]] && existing_studies=$((existing_studies + 1))
done
if [[ "$mode" == guard ]] && (( existing_studies > 0 )); then
    print_status >&2
    ae_die "existing profile studies found; use --resume to preserve them or --fresh to back them up"
fi

printf 'AE4 optional GAPBS retraining\n'
printf '  profile        : %s\n' "$profile"
printf '  threshold      : %s\n' "$threshold"
printf '  workloads      : %s\n' "${workloads[*]}"
printf '  target         : 5 workloads x 20 successful invocations = 100 rows\n'
printf '  trial interval : %s seconds\n' "$trial_interval_sec"
printf '  epoch order    : odd 400000/400001; even 400001/400000\n'
printf '  objective      : printed GAPBS Average Time (all 10 trials)\n'
printf '  output         : %s\n\n' "$training_root"

for index in "${!workloads[@]}"; do
    workload="${workloads[$index]}"
    study_dir="${training_root}/${keys[$index]}"
    argv=(
        bash "${SCRIPT_DIR}/run_training_gapbs.sh" "$workload"
        --threshold "$threshold"
        --target-trials 20
        --profile "$profile"
        --trial-interval-sec "$trial_interval_sec"
    )
    case "$mode" in
        fresh) argv+=(--fresh) ;;
        resume)
            [[ -e "$study_dir" ]] && argv+=(--resume)
            ;;
    esac
    (( auto_yes == 1 )) && argv+=(--yes)

    printf '\n===== GAPBS training %d/5: %s =====\n' "$((index + 1))" "$workload"
    if (( dry_run == 1 )); then
        printf 'DRY-RUN:'
        printf ' %q' "${argv[@]}"
        printf '\n'
        continue
    fi
    if "${argv[@]}"; then
        :
    else
        runner_rc=$?
        printf 'ERROR: %s stopped; validated prior rows were preserved.\n' "$workload" >&2
        printf 'Rerun this all-five command with --resume after fixing the reported cause.\n' >&2
        exit "$runner_rc"
    fi
    if (( index + 1 < ${#workloads[@]} && workload_interval_sec > 0 )); then
        printf '[interval] Waiting %s seconds before the next GAPBS workload.\n' \
            "$workload_interval_sec"
        sleep "$workload_interval_sec"
    fi
done

if (( dry_run == 1 )); then
    if (( skip_lobo == 0 )); then
        printf 'DRY-RUN: bash %q gap --threshold %q --source training --profile %q' \
            "${SCRIPT_DIR}/generate_lobo_configs.sh" "$threshold" "$profile"
        (( auto_yes == 1 )) && printf ' --yes'
        printf '\n'
    fi
    exit 0
fi

python3 "${SCRIPT_DIR}/validate_training_histories.py" \
    --root "$training_root" --suite gapbs --threshold "$threshold" --target 20

if (( skip_lobo == 0 )); then
    lobo_argv=(
        bash "${SCRIPT_DIR}/generate_lobo_configs.sh" gap
        --threshold "$threshold"
        --source training
        --profile "$profile"
    )
    (( auto_yes == 1 )) && lobo_argv+=(--yes)
    "${lobo_argv[@]}"
fi

printf '\nAll five GAPBS histories are complete and validated.\n'
print_status
if (( skip_lobo == 0 )); then
    printf 'Model root: %s\n' \
        "${ARTIFACT_DIR}/results/retraining/${profile}/models/th${threshold}/gap"
fi
