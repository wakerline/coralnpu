#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-clean}"

log() {
    echo "$@"
}

delete_path() {
    local path="$1"
    if [[ -e "$path" ]]; then
        if [[ "$MODE" == "dry-run" ]]; then
            log "WOULD DELETE: $path"
        else
            log "DELETE: $path"
            rm -rf -- "$path"
        fi
    fi
}

delete_glob() {
    local pattern="$1"
    shopt -s nullglob
    local matches=( $pattern )
    shopt -u nullglob

    for path in "${matches[@]}"; do
        if [[ -e "$path" ]]; then
            if [[ "$MODE" == "dry-run" ]]; then
                log "WOULD DELETE: $path"
            else
                log "DELETE: $path"
                rm -rf -- "$path"
            fi
        fi
    done
}

usage() {
    cat <<'EOF2'
Usage:
  ./clean.sh           # clean generated files
  ./clean.sh dry-run   # preview only
  ./clean.sh help      # show help
EOF2
}

if [[ "$MODE" == "help" || "$MODE" == "-h" || "$MODE" == "--help" ]]; then
    usage
    exit 0
fi

if [[ "$MODE" != "clean" && "$MODE" != "dry-run" ]]; then
    echo "ERROR: unsupported mode: $MODE"
    usage
    exit 1
fi

log "=== DC clean start ($MODE) ==="

exact_targets=(
    "work"
    "dc.log"
    "command.log"
    "filenames.log"
    "source_sdc.log"
    "qor.csv"
    "off"
)

glob_targets=(
    "alib-*"
    "dc.out*"
    "*.svf"
    "*.svf.*"
    "*~"
)

for path in "${exact_targets[@]}"; do
    delete_path "$path"
done

for pattern in "${glob_targets[@]}"; do
    delete_glob "$pattern"
done

log "=== DC clean done ==="
