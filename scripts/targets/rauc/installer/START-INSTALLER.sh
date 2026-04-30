#!/bin/sh
# One-click entry point for file managers and terminal users.

set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
exec "$SCRIPT_DIR/install-gui.sh" "$@"
