#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/lib.sh"
cd "$GLIFF_ROOT"
require_macos

xcodebuild \
  -project macos/GliffMac.xcodeproj \
  -scheme GliffMac \
  -configuration Debug \
  -destination 'generic/platform=macOS' \
  -derivedDataPath "$GLIFF_ROOT/build/DerivedData" \
  'ARCHS=arm64 x86_64' \
  ONLY_ACTIVE_ARCH=NO \
  CODE_SIGNING_ALLOWED=NO \
  build
