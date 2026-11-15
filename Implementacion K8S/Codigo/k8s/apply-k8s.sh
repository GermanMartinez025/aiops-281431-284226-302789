#!/usr/bin/env bash
# Solo instalacion inicial. Para actualizar: update-app.sh.
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec node "$SCRIPT_DIR/install.mjs" "$@"
