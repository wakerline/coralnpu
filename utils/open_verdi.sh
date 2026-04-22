#!/usr/bin/env bash

set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 //<pkg>:<target>" >&2
  exit 1
fi

if ! command -v verdi >/dev/null 2>&1; then
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

dbdir="$(find "$search_dir" -maxdepth 4 -type d \( -name '*.daidir' -o -name '*.kdb' \) | sort | head -n 1)"
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
  echo "Note: no Verdi compile database (.daidir/.kdb) was exported by Bazel." >&2
  echo "      Opening FSDB only. Coverage DB is available at: $covdir" >&2
fi
exec "${cmd[@]}"
