#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/lib.sh"
cd "$GLIFF_ROOT"

require_command git
require_command python3
if [[ -e vendor/gliff/.git ]] && [[ -n "$(git -C vendor/gliff status --porcelain)" ]]; then
  printf 'vendor/gliff has local changes; preserve them before bootstrapping.\n' >&2
  exit 1
fi
git submodule sync --recursive
git submodule update --init --recursive --checkout

require_command rustup
require_command cargo
require_command cc
rustup toolchain install 1.90.0 --profile minimal --component rustfmt,clippy
if [[ "$(uname -s)" == Darwin ]]; then
  require_macos
  rustup target add aarch64-apple-darwin x86_64-apple-darwin
fi
cargo fetch --locked
python3 scripts/check-structure.py
printf 'Bootstrap complete. Run scripts/check.sh.\n'
