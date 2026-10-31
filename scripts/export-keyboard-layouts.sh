#!/usr/bin/env bash
# Production keymaps and matching Apple translation data (ANSI/ISO), as JSON.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
cd "$GLIFF_ROOT"
require_macos
out="$GLIFF_ROOT/build/input-layouts"
mkdir -p "$out"
xcrun swiftc macos/GliffMac/Input/KeyCodes.swift \
  macos/GliffMac/Input/KeyboardLayout.swift macos/GliffMac/Input/MacKeymap.swift \
  tools/keyboard-layouts/main.swift -o "$out/export"
"$out/export" > "$out/layouts.json"
printf '%s\n' "$out/layouts.json"
