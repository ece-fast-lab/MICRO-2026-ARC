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
  run_sampling.sh gapbs <bc|bfs|cc|pr> <web|twitter> --sampling <spl1|spl2|spl4> [options]
  run_sampling.sh spec <numeric-id> --sampling <spl1|spl2|spl4> --threshold <16|32|64|96> [options]

Optional sampling-ratio run.  It only runs workloads; it never programs a POF
or reboots SPR1.

Options:
  --sampling <spl1|spl2|spl4>    Required; declares the currently loaded POF
  --threshold <16|32|64|96>     GAPBS defaults: SPL1=64, SPL2=32, SPL4=16;
                                 required explicitly for SPEC
  --method <cache|cms|both>      Default: both
  --resume                       Reuse valid canonical logs
  -y, --yes, all yes             Confirm the declared POF/reruns automatically
  -h, --help                     Show this help
EOF
}

(( $# > 0 )) || { usage >&2; exit 2; }
suite="$1"
shift
case "$suite" in
    gap|gapbs)
        suite="gapbs"
        (( $# >= 2 )) || { usage >&2; exit 2; }
        benchmark="$1"; database="$2"; shift 2
        case "$benchmark" in bc|bfs|cc|pr) ;; *) ae_die "invalid GAPBS benchmark: $benchmark" ;; esac
        case "$database" in web|twitter) ;; *) ae_die "invalid GAPBS database: $database" ;; esac
        workload_key="${benchmark}_${database}"
        ;;
    spec)
        (( $# >= 1 )) || { usage >&2; exit 2; }
        benchmark="$1"; database=""; shift
        [[ "$benchmark" =~ ^[0-9]+$ ]] || ae_die "SPEC benchmark must be a numeric ID"
        workload_key="$benchmark"
        ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; ae_die "suite must be gapbs or spec" ;;
esac

sampling=""
threshold=""
method="both"
resume=0
auto_yes=0
if (( $# >= 2 )) && [[ "$1" == all && "$2" == yes ]]; then
    auto_yes=1
    shift 2
fi
while (( $# > 0 )); do
    case "$1" in
        --sampling)
            (( $# >= 2 )) || ae_die "--sampling requires a value"
            sampling="${2,,}"; shift 2; continue ;;
        --threshold)
            (( $# >= 2 )) || ae_die "--threshold requires a value"
            threshold="$2"; shift 2; continue ;;
        --method)
            (( $# >= 2 )) || ae_die "--method requires a value"
            method="${2,,}"; shift 2; continue ;;
        --resume) resume=1 ;;
        -y|--yes|--all-yes) auto_yes=1 ;;
        all)
            (( $# >= 2 )) && [[ "$2" == yes ]] || ae_die "'all' must be followed by 'yes'"
            auto_yes=1; shift 2; continue ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; ae_die "unknown option: $1" ;;
    esac
    shift
done
case "$sampling" in spl1|spl2|spl4) ;; *) ae_die "--sampling must be spl1, spl2, or spl4" ;; esac
case "$method" in cache|cms|both) ;; *) ae_die "--method must be cache, cms, or both" ;; esac

if [[ -z "$threshold" ]]; then
    if [[ "$suite" == spec ]]; then
        ae_die "SPEC sampling requires --threshold because legacy SPEC mappings are inconsistent"
    fi
    case "$sampling" in
        spl1) threshold=64 ;;
        spl2) threshold=32 ;;
        spl4) threshold=16 ;;
    esac
fi
case "$threshold" in 16|32|64|96) ;; *) ae_die "--threshold must be 16, 32, 64, or 96" ;; esac

sampling_rate="${sampling#spl}"
pof_name="chmu_ae_merge_${sampling^^}.pof"
printf '\nOptional sampling-ratio run\n'
printf '  suite/workload : %s / %s\n' "$suite" "$workload_key"
printf '  declared image : %s (sample 1/%s accesses)\n' "${sampling^^}" "$sampling_rate"
printf '  expected POF   : %s\n' "$pof_name"
printf '  threshold      : %s\n' "$threshold"
printf '  methods        : %s\n' "$method"
printf '  warning        : no runtime CSR identifies the sampling image\n\n'
ae_confirm "$auto_yes" "Confirm that ${pof_name} is loaded and SPR1 was power-cycled" || {
    printf 'Stopped before any benchmark.\n'
    exit 0
}

ae_load_platform "$ARTIFACT_DIR"
ae_runner_env
out_base="${ARTIFACT_DIR}/results/sampling/${suite}/${workload_key}/${sampling}/runs"
mkdir -p "$out_base"
point_records=()
if [[ "$method" == both ]]; then methods=(cache cms); else methods=("$method"); fi

for method_name in "${methods[@]}"; do
    if [[ "$method_name" == cache ]]; then epoch=400000; else epoch=400001; fi
    tag="sampling_${sampling}_${method_name}_th${threshold}"
    if [[ "$suite" == gapbs ]]; then
        run_dir="${out_base}/${threshold}_${epoch}_${epoch}_1_${benchmark}_${database}_mig_${tag}"
        workload_log="${run_dir}/${benchmark}_${database}.log"
        if (( resume == 1 )) && ae_gap_run_valid "$run_dir" "$workload_log"; then
            printf '[reuse] %s\n' "$workload_log"
            point_records+=("${method_name},reused,${run_dir}")
            continue
        fi
    else
        run_dir="${out_base}/${threshold}_${epoch}_${epoch}_1_${benchmark}_mig_${tag}"
        workload_log="${run_dir}/${benchmark}.log"
        if (( resume == 1 )) && ae_spec_run_valid "$run_dir" "$workload_log"; then
            printf '[reuse] %s\n' "$workload_log"
            point_records+=("${method_name},reused,${run_dir}")
            continue
        fi
    fi

    if [[ -e "$run_dir" || -e "${run_dir}.log" ]]; then
        ae_confirm "$auto_yes" "Rerun ${method_name} and let the runner move old output to .bak?" || {
            printf '[skip] %s\n' "$run_dir"
            point_records+=("${method_name},skipped_by_user,${run_dir}")
            continue
        }
    else
        ae_confirm "$auto_yes" "Run ${method_name} now?" || {
            printf '[skip] %s\n' "$run_dir"
            point_records+=("${method_name},skipped_by_user,${run_dir}")
            continue
        }
    fi

    if [[ "$suite" == gapbs ]]; then
        ae_run_gapbs_point "$SW_DIR" "$out_base" "$threshold" "$epoch" \
            "$benchmark" "$database" mig "$tag"
    else
        ae_run_spec_point "$SW_DIR" "$out_base" "$threshold" "$epoch" \
            "$benchmark" mig "$tag"
    fi
    if [[ "$suite" == gapbs ]]; then
        ae_gap_run_valid "$run_dir" "$workload_log" || ae_die "completed point failed validation: $run_dir"
    else
        ae_spec_run_valid "$run_dir" "$workload_log" || ae_die "completed point failed validation: $run_dir"
    fi
    point_records+=("${method_name},completed,${run_dir}")
done

manifest="${ARTIFACT_DIR}/results/sampling/${suite}/${workload_key}/${sampling}/run_manifest.txt"
{
    printf 'experiment=sampling_ratio\n'
    printf 'suite=%s\nworkload=%s\n' "$suite" "$workload_key"
    printf 'declared_pof=%s\nsampling_rate=%s\n' "${sampling^^}" "$sampling_rate"
    printf 'threshold=%s\npoll_ms=1\nmethod=%s\n' "$threshold" "$method"
    for point_record in "${point_records[@]}"; do
        printf 'point=%s\n' "$point_record"
    done
    printf 'recorded_at=%s\n' "$(TZ=America/Chicago date --iso-8601=seconds)"
} > "$manifest"
printf '\nSaved optional run manifest: %s\n' "$manifest"
