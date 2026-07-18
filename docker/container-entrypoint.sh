#!/bin/bash

set -euo pipefail

OUTPUT_ROOT="${OUTPUT_ROOT:-/workspace/scripts}"
HOST_UID="${HOST_UID:-}"
HOST_GID="${HOST_GID:-}"
CHOWN_OUTPUTS="${CHOWN_OUTPUTS:-1}"

function chown_outputs() {
    if [[ "$CHOWN_OUTPUTS" != "1" ]]; then
        return 0
    fi

    if [[ -z "$HOST_UID" || -z "$HOST_GID" ]]; then
        return 0
    fi

    if [[ -d "$OUTPUT_ROOT/image" ]]; then
        chown -R "$HOST_UID:$HOST_GID" "$OUTPUT_ROOT/image" || true
    fi

    if [[ -d "$OUTPUT_ROOT/reports" ]]; then
        chown -R "$HOST_UID:$HOST_GID" "$OUTPUT_ROOT/reports" || true
    fi

    # RAUC target output: <repo>/out/*.raucb (build-bundle.sh пишет туда от root).
    local rauc_out
    rauc_out="$(dirname "$OUTPUT_ROOT")/out"
    if [[ -d "$rauc_out" ]]; then
        chown -R "$HOST_UID:$HOST_GID" "$rauc_out" || true
    fi

    find "$OUTPUT_ROOT" -maxdepth 1 -type f \( -name '*.iso' -o -name '*.raucb' \) \
        -exec chown "$HOST_UID:$HOST_GID" {} + 2>/dev/null || true
}

status=0
trap 'status=$?; chown_outputs; exit $status' EXIT

if [[ $# -eq 0 ]]; then
    set -- ./scripts/build.sh -
fi

"$@"
