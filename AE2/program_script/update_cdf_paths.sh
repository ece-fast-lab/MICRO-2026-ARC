#!/usr/bin/env bash

set -euo pipefail

# Use the directory containing this script, even when called from elsewhere.
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

shopt -s nullglob
cdf_files=("${script_dir}"/*.cdf)

if ((${#cdf_files[@]} == 0)); then
    echo "No .cdf files found in: ${script_dir}" >&2
    exit 1
fi

# Escape characters that have a special meaning in a sed replacement.
escaped_dir=${script_dir//\\/\\\\}
escaped_dir=${escaped_dir//&/\\&}
escaped_dir=${escaped_dir//|/\\|}

updated=0
for cdf_file in "${cdf_files[@]}"; do
    if grep -qE 'PFLPath\("[^"]*/[^/"]+\.pof"\)' "${cdf_file}"; then
        backup_file="${cdf_file}.bak"
        if [[ ! -e "${backup_file}" ]]; then
            cp -p -- "${cdf_file}" "${backup_file}"
        fi

        sed -E -i \
            "s|PFLPath\\(\"[^\"]*/([^/\"]+\\.pof)\"\\)|PFLPath(\"${escaped_dir}/\\1\")|g" \
            "${cdf_file}"
        echo "Updated: $(basename -- "${cdf_file}")"
        ((updated += 1))
    else
        echo "Skipped (no PFLPath found): $(basename -- "${cdf_file}")" >&2
    fi
done

echo "Done: ${updated} file(s) now use ${script_dir}"
