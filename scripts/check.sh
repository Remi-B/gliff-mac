#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/lib.sh"
cd "$GLIFF_ROOT"
require_command cargo
require_command python3

python3 scripts/check-structure.py
cargo fmt --all --check
cargo clippy --workspace --all-targets --locked -- -D warnings
cargo test --workspace --locked
fixture_gen=tools/fixture-gen/Cargo.toml
cargo fmt --manifest-path "$fixture_gen" --check
cargo clippy --manifest-path "$fixture_gen" --all-targets --locked -- -D warnings
cargo test --manifest-path "$fixture_gen" --locked
scripts/generate-fixtures.sh --check
git diff --check

if [[ "$(uname -s)" == Darwin ]]; then
  require_macos
  export MACOSX_DEPLOYMENT_TARGET=13.0
  for target in aarch64-apple-darwin x86_64-apple-darwin; do
    cargo check --workspace --all-targets --locked --target "$target"
  done
  scripts/audit-portability.sh
  swift build --package-path macos/Packages/GliffCore
  scripts/build-app.sh
else
  printf 'Rust/structure checks passed. Apple target and app builds require macOS.\n'
fi
