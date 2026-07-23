#!/usr/bin/env bash

set -euo pipefail

dry_run=0
if [[ "${1:-}" == "--dry-run" ]]; then
  dry_run=1
  shift
fi

if [[ $# -ne 1 ]]; then
  echo "usage: $0 [--dry-run] //<pkg>:<target>" >&2
  exit 1
fi

if [[ "$dry_run" -eq 0 ]] && ! command -v verdi >/dev/null 2>&1; then
  echo "verdi not found in PATH" >&2
  exit 1
fi

target="$1"
target="${target#//}"

if [[ "$target" != *:* ]]; then
  echo "expected a Bazel label like //tests/cocotb:target" >&2
  exit 1
fi

pkg="${target%%:*}"
name="${target##*:}"
workspace_dir="${BUILD_WORKSPACE_DIRECTORY:-$(pwd)}"
outputs_dir="${workspace_dir}/bazel-testlogs/${pkg}/${name}/test.outputs"
test_log="${workspace_dir}/bazel-testlogs/${pkg}/${name}/test.log"
bazel_bin="${workspace_dir}/bazel-bin"

if [[ ! -d "$outputs_dir" ]]; then
  echo "missing test outputs: $outputs_dir" >&2
  echo "run 'bazel test --config=vcs //$pkg:$name' first" >&2
  exit 1
fi

search_dir="$outputs_dir"
zip_file="${outputs_dir}/outputs.zip"
if [[ -f "$zip_file" ]]; then
  search_dir="$(mktemp -d "${TMPDIR:-/tmp}/open_verdi.XXXXXX")"
  unzip -oq "$zip_file" -d "$search_dir"
fi

fsdb_file="$(find "$search_dir" -maxdepth 4 -type f -name '*.fsdb' | sort | head -n 1)"
if [[ -z "${fsdb_file:-}" ]]; then
  echo "no FSDB file found under $search_dir" >&2
  exit 1
fi

dbdir="$(find "$search_dir" -maxdepth 4 -type d -name '*.daidir' | sort | head -n 1)"

# Bazel exports the FSDB as a test output, but a precompiled VCS model's
# simv.daidir remains under bazel-bin. Recover that model from the test log.
if [[ -z "${dbdir:-}" && -f "$test_log" ]]; then
  model_line="$(grep 'Using pre-compiled VCS model from ' "$test_log" | tail -n 1 || true)"
  if [[ -n "$model_line" && "$model_line" == */coralnpu_hw/* ]]; then
    model_rel="${model_line##*/coralnpu_hw/}"
    if [[ "$model_rel" == */simv ]]; then
      model_dbdir="${bazel_bin}/${model_rel%/simv}/simv.daidir"
      if [[ -d "$model_dbdir" ]]; then
        dbdir="$model_dbdir"
      fi
    fi
  fi
fi

# Fall back to the longest model-name prefix matching the test target. This
# handles older test logs and tests whose output directory was copied.
if [[ -z "${dbdir:-}" && -d "${bazel_bin}/${pkg}" ]]; then
  best_prefix_length=0
  while IFS= read -r model_dbdir; do
    model_build="$(basename "$(dirname "$model_dbdir")")"
    model_prefix="${model_build%_vcs_model_vcs_build}"
    if [[ "$name" == "$model_prefix" || "$name" == "$model_prefix"_* ]]; then
      if (( ${#model_prefix} > best_prefix_length )); then
        dbdir="$model_dbdir"
        best_prefix_length="${#model_prefix}"
      fi
    fi
  done < <(
    find "${bazel_bin}/${pkg}" -maxdepth 2 -type d \
      -path '*_vcs_model_vcs_build/simv.daidir' | sort
  )
fi

covdir="$(find "$search_dir" -maxdepth 4 -type d -name '*.vdb' | sort | head -n 1)"

cmd=(verdi -ssf "$fsdb_file")
if [[ -n "${dbdir:-}" ]]; then
  cmd+=(-dbdir "$dbdir")
fi

echo "Target label : //$pkg:$name"
echo "Test outputs : $outputs_dir"
if [[ -f "$zip_file" ]]; then
  echo "Outputs zip  : $zip_file"
  echo "Extracted to : $search_dir"
else
  echo "Search dir   : $search_dir"
fi
echo "FSDB file    : $fsdb_file"
if [[ -n "${dbdir:-}" ]]; then
  echo "DB dir       : $dbdir"
else
  echo "DB dir       : <none>"
fi
if [[ -n "${covdir:-}" ]]; then
  echo "Coverage DB  : $covdir"
else
  echo "Coverage DB  : <none>"
fi
echo "Launching: ${cmd[*]}"
if [[ -z "${dbdir:-}" && -n "${covdir:-}" ]]; then
  echo "Note: no Verdi compile database (.daidir) was found." >&2
  echo "      Opening FSDB only. Coverage DB is available at: $covdir" >&2
fi
if [[ "$dry_run" -eq 1 ]]; then
  exit 0
fi
exec "${cmd[@]}"
