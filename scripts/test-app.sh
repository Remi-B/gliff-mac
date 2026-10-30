#!/usr/bin/env bash
# Run the app's hosted test bundle (view model, session lifecycle, persistence
# and a bridge replay) through the shared scheme's test action.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
cd "$GLIFF_ROOT"
require_macos

# The GliffCore package references the generated XCFramework.
[[ -d macos/Packages/GliffCore/Artifacts/GliffCoreFFI.xcframework ]] || scripts/build-bridge.sh

xcodebuild \
  -project macos/GliffMac.xcodeproj \
  -scheme GliffMac \
  -configuration Debug \
  -destination "platform=macOS,arch=$(uname -m)" \
  -derivedDataPath "$GLIFF_ROOT/build/DerivedData" \
  test
