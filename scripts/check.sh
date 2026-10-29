#!/usr/bin/env bash
# Run every compatibility gate this host can run; see scripts/gates.py.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
cd "$GLIFF_ROOT"
require_command cargo
require_command python3
[[ "$(uname -s)" == Darwin ]] && require_macos

exec python3 scripts/gates.py "$@"
