#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SW_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
ARTIFACT_DIR="$(cd -- "${SW_DIR}/.." && pwd)"

usage() {
    cat <<'EOF'
Usage:
  plot_fig11_primary_combined.sh [options]

Validate and regenerate the existing Figure 11 summaries for bc_tw, bfs_tw,
and pr_tw, then draw one grouped plot containing those workloads plus their
cross-workload geometric mean. This command is processing-only: it never
starts a benchmark or changes hardware state.

Options:
  --threshold <16|32|64|96>  Result threshold to process (default: 16)
  --output-prefix <path>      Output path without .png/.pdf (default:
                              results/figure11/thN/
                              figure11_primary_combined_normalized_performance)
  --model-root <directory>   Validate results generated with this cfg root
  --result-profile <name>    Read isolated figure11_profiles/<name> results;
                             required with --model-root
  --title <text>              Figure title (default includes threshold)
  --dpi <positive-integer>    PNG resolution (default: 300)
  -h, --help                  Show this help

The output has four workload groups: bc_tw, bfs_tw, pr_tw, and GeoMean. Each
group contains CXL-only, CHMU-Cache, CHMU-CMS, and Adaptive. GeoMean is
computed separately for each method from its three normalized-performance
values. Each workload's Adaptive value already represents the faster of its
two complete epoch-direction candidates.
EOF
}

threshold=16
output_prefix=""
title=""
dpi=300
model_root=""
result_profile=""
while (( $# > 0 )); do
    case "$1" in
        --threshold)
            (( $# >= 2 )) || { printf 'ERROR: --threshold requires a value\n' >&2; exit 2; }
            threshold="$2"
            shift 2
            ;;
        --output-prefix)
            (( $# >= 2 )) || { printf 'ERROR: --output-prefix requires a value\n' >&2; exit 2; }
            output_prefix="$2"
            shift 2
            ;;
        --model-root)
            (( $# >= 2 )) || { printf 'ERROR: --model-root requires a value\n' >&2; exit 2; }
            model_root="$2"
            shift 2
            ;;
        --result-profile)
            (( $# >= 2 )) || { printf 'ERROR: --result-profile requires a value\n' >&2; exit 2; }
            result_profile="$2"
            shift 2
            ;;
        --title)
            (( $# >= 2 )) || { printf 'ERROR: --title requires a value\n' >&2; exit 2; }
            title="$2"
            shift 2
            ;;
        --dpi)
            (( $# >= 2 )) || { printf 'ERROR: --dpi requires a value\n' >&2; exit 2; }
            dpi="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            usage >&2
            printf 'ERROR: unknown option: %s\n' "$1" >&2
            exit 2
            ;;
    esac
done

case "$threshold" in
    16|32|64|96) ;;
    *)
        printf 'ERROR: --threshold must be 16, 32, 64, or 96\n' >&2
        exit 2
        ;;
esac
[[ "$dpi" =~ ^[1-9][0-9]*$ ]] || {
    printf 'ERROR: --dpi must be a positive integer\n' >&2
    exit 2
}
[[ -z "$result_profile" || "$result_profile" =~ ^[A-Za-z0-9._-]+$ ]] || {
    printf 'ERROR: --result-profile has invalid characters\n' >&2
    exit 2
}
if [[ -n "$model_root" && -z "$result_profile" ]]; then
    printf 'ERROR: --model-root requires --result-profile\n' >&2
    exit 2
fi

command -v python3 >/dev/null 2>&1 || {
    printf 'ERROR: python3 is required for Figure 11 plotting.\n' >&2
    exit 1
}
[[ -r "${SCRIPT_DIR}/run_figure11.sh" ]] || {
    printf 'ERROR: missing Figure 11 processing runner: %s\n' \
        "${SCRIPT_DIR}/run_figure11.sh" >&2
    exit 1
}
[[ -r "${SCRIPT_DIR}/plot_figure11_combined.py" ]] || {
    printf 'ERROR: missing combined Figure 11 plotter: %s\n' \
        "${SCRIPT_DIR}/plot_figure11_combined.py" >&2
    exit 1
}
if ! python3 -c 'import matplotlib' >/dev/null 2>&1; then
    cat >&2 <<'EOF'
ERROR: Matplotlib is unavailable or incompatible in this Python environment.
Use the documented system-package environment:
  env PYTHONNOUSERSITE=1 PYTHONPATH=/usr/lib/python3/dist-packages \
    bash sw/fig11/plot_fig11_primary_combined.sh --threshold 16
or activate the plotting-only virtual environment first.
EOF
    exit 1
fi

results_root="${AE4_RESULTS_ROOT:-${ARTIFACT_DIR}/results}"
run_profile_args=()
if [[ -n "$result_profile" ]]; then
    result_namespace="figure11_profiles/${result_profile}"
    run_profile_args+=(--result-profile "$result_profile")
else
    result_namespace=figure11
fi
if [[ -n "$model_root" ]]; then
    run_profile_args+=(--model-root "$model_root")
fi
workloads=(bc_tw bfs_tw pr_tw)
workload_keys=(bc_twitter bfs_twitter pr_twitter)

printf 'Figure 11 combined processing-only plot\n'
printf '  threshold : %s\n' "$threshold"
printf '  workloads : bc_tw, bfs_tw, pr_tw, GeoMean\n'
for workload in "${workloads[@]}"; do
    printf '\n[validate] %s\n' "$workload"
    bash "${SCRIPT_DIR}/run_figure11.sh" "$workload" \
        --threshold "$threshold" \
        "${run_profile_args[@]}" \
        --method all \
        --skip-benchmark \
        --skip-plot
done

# run_figure11.sh creates the configured result root if needed and resolves the
# same path from the caller's working directory. Canonicalize it only after all
# three processing-only validations have succeeded.
results_root="$(cd -- "$results_root" && pwd)"
if [[ -z "$output_prefix" ]]; then
    output_prefix="${results_root}/${result_namespace}/th${threshold}/figure11_primary_combined_normalized_performance"
fi
if [[ -z "$title" ]]; then
    title="Figure 11: GAPBS primary workloads, threshold ${threshold}"
fi

python3 "${SCRIPT_DIR}/plot_figure11_combined.py" \
    --input "bc_tw=${results_root}/${result_namespace}/th${threshold}/${workload_keys[0]}/figure11_results.csv" \
    --input "bfs_tw=${results_root}/${result_namespace}/th${threshold}/${workload_keys[1]}/figure11_results.csv" \
    --input "pr_tw=${results_root}/${result_namespace}/th${threshold}/${workload_keys[2]}/figure11_results.csv" \
    --output-prefix "$output_prefix" \
    --title "$title" \
    --dpi "$dpi"
