#!/usr/bin/env bash
# Solo construye/carga; actualizar requiere update-app y prueba funcional.
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec node "$SCRIPT_DIR/build-images.mjs" --app ui "$@"
