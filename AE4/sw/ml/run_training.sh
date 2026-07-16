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
  run_training.sh gapbs <bc_tw|bfs_tw|cc_tw|pr_tw|pr_web> [options]
  run_training.sh spec  <gcc|mcf|cactuB|cam4|roms> [options]

Run the optional per-workload configuration study. The default target is 20
successful complete benchmark executions, not 20 additional executions.

Options:
  --threshold <16|32|64|96>  CHMU threshold (default: 16)
  --target-trials <N>        Total successful trials desired (default: 20)
  --resume                   Continue the existing validated history up to N
  --fresh                    Back up an existing study to .bakN and start over
  all yes, -y, --yes         Confirm the SPL1 image and long-running study
  -h, --help                 Show this help

Odd trials start with 400000/400001; even trials reverse the starting order.
Failed or incomplete runs are never appended to history. This script never
programs a POF or reboots SPR1. Trials run strictly sequentially. If another
ARC command owns the shared host lock, this optional study stops; rerun the
same command with --resume after the other command finishes.
EOF
}

if (( $# == 1 )) && [[ "$1" == -h || "$1" == --help ]]; then
    usage
    exit 0
fi
(( $# >= 2 )) || { usage >&2; exit 2; }
suite="$1"
selector="$2"
shift 2
case "$suite:$selector" in
    gapbs:-h|gapbs:--help|spec:-h|spec:--help) usage; exit 0 ;;
    gapbs:bc_tw|gapbs:bc_twitter)
        benchmark=bc; database=twitter; workload_key=bc_twitter ;;
    gapbs:bfs_tw|gapbs:bfs_twitter)
        benchmark=bfs; database=twitter; workload_key=bfs_twitter ;;
    gapbs:cc_tw|gapbs:cc_twitter)
        benchmark=cc; database=twitter; workload_key=cc_twitter ;;
    gapbs:pr_tw|gapbs:pr_twitter)
        benchmark=pr; database=twitter; workload_key=pr_twitter ;;
    gapbs:pr_web)
        benchmark=pr; database=web; workload_key=pr_web ;;
    spec:gcc|spec:502)
        benchmark=502; database=; workload_key=502 ;;
    spec:mcf|spec:505)
        benchmark=505; database=; workload_key=505 ;;
    spec:cactuB|spec:cactub|spec:cactuBSSN|spec:507)
        benchmark=507; database=; workload_key=507 ;;
    spec:cam4|spec:527)
        benchmark=527; database=; workload_key=527 ;;
    spec:roms|spec:554)
        benchmark=554; database=; workload_key=554 ;;
    *) usage >&2; ae_die "unsupported ${suite} training workload: ${selector}" ;;
esac

threshold=16
target_trials=20
auto_yes=0
resume=0
fresh=0
while (( $# > 0 )); do
    case "$1" in
        --threshold)
            (( $# >= 2 )) || ae_die "--threshold requires a value"
            threshold="$2"; shift 2; continue ;;
        --target-trials|--trials)
            (( $# >= 2 )) || ae_die "$1 requires a value"
            target_trials="$2"; shift 2; continue ;;
        --resume) resume=1 ;;
        --fresh) fresh=1 ;;
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
[[ "$target_trials" =~ ^[1-9][0-9]*$ ]] || ae_die "target trial count must be positive"
(( resume == 0 || fresh == 0 )) || ae_die "--resume and --fresh are mutually exclusive"

command -v python3 >/dev/null 2>&1 || ae_die "python3 is required"
python3 -c 'import sklearn' >/dev/null 2>&1 || \
    ae_die "scikit-learn is required (for example: python3 -m pip install scikit-learn)"

ae_load_platform "$ARTIFACT_DIR"
[[ "$CXL_NODE" == 1 && "$BUFFER_NODE" == 0 ]] || \
    ae_die "training requires CXL_NODE=1 and BUFFER_NODE=0"
[[ -x "${SW_DIR}/build_option_th${threshold}/migration_manager" ]] || \
    ae_die "threshold ${threshold} manager is not built; run set_default/setup_default.sh build"

benchmark_paths_file="${BENCHMARK_PATHS_FILE:-${SW_DIR}/config/benchmark_paths.env}"
[[ -r "$benchmark_paths_file" ]] || ae_die "missing benchmark path configuration: $benchmark_paths_file"
# shellcheck source=/dev/null
source "$benchmark_paths_file"
if [[ "$suite" == gapbs ]]; then
    [[ -d "${GAPBS_ROOT:-}" && -x "${GAPBS_ROOT}/${benchmark}" ]] || \
        ae_die "GAPBS binary is unavailable: ${GAPBS_ROOT:-unset}/${benchmark}"
else
    [[ -x "${SPEC_RUNCPU:-}" && -r "${SPEC_CONFIG:-}" ]] || \
        ae_die "SPEC_RUNCPU/SPEC_CONFIG is not ready in $benchmark_paths_file"
fi

ae_confirm "$auto_yes" "Confirm that the SPL1 POF is loaded and run the optional long ${target_trials}-trial ${workload_key} study" || {
    printf 'Stopped before any benchmark.\n'
    exit 0
}

study_dir="${ARTIFACT_DIR}/results/training/th${threshold}/${suite}/${workload_key}"
if [[ -e "$study_dir" && "$resume" == 0 ]]; then
    if (( fresh == 0 )); then
        ae_confirm "$auto_yes" "Existing study found for ${workload_key}; back it up to .bakN and start a fresh ${target_trials}-trial study?" || {
            printf 'Stopped. Use --resume to continue the existing history.\n'
            exit 0
        }
    fi
    backup_index=0
    while [[ -e "${study_dir}.bak${backup_index}" ]]; do backup_index=$((backup_index + 1)); done
    mv -- "$study_dir" "${study_dir}.bak${backup_index}"
    printf 'Backed up: %s\n' "${study_dir}.bak${backup_index}"
elif [[ ! -e "$study_dir" && "$resume" == 1 ]]; then
    ae_die "--resume requested but no study exists: $study_dir"
fi

argv=(
    python3 "${SCRIPT_DIR}/optimize_runtime_model.py"
    --artifact-dir "$ARTIFACT_DIR"
    --suite "$suite"
    --benchmark "$benchmark"
    --threshold "$threshold"
    --target-trials "$target_trials"
    --epoch-a 400000
    --epoch-b 400001
    --poll-ms 1
    --predictor-interval-ms 10
)
if [[ "$suite" == gapbs ]]; then
    argv+=(--db "$database")
else
    argv+=(--copies 8)
fi
"${argv[@]}"

printf '\nTraining study complete: %s\n' "$study_dir"
printf 'Run all five workloads in this suite before suite-isolated LOBO generation.\n'
