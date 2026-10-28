#!/usr/bin/env bash
# Prove the application's selected upstream crates build for both Apple
# targets without the Linux client stack, and record the evidence.
#
# Writes logs and a summary under build/portability/ (ignored by Git).
set -euo pipefail
source "$(dirname "$0")/lib.sh"
cd "$GLIFF_ROOT"
require_command cargo
require_macos
require_command lipo
require_command vtool

export MACOSX_DEPLOYMENT_TARGET=13.0
out=build/portability
rm -rf "$out"
mkdir -p "$out"
summary="$out/summary.txt"
# Crates that would mean the Linux client, compositor, GPU or encoder stack
# leaked into the app: GTK/GLib, Wayland/XKB, Hyprland, DRM/GBM, VA-API,
# Vulkan, OpenH264 (upstream's CPU video crate) and D-Bus.
forbidden='^(gtk|gdk|glib|gio|gobject|cairo|pango|libadwaita|wayland-|xkbcommon|calloop|hypr-|drm|gbm|libva|ash|vulkan|gliff-vk|gliff-va|gliff-sw|gliff-server|openh264|dbus)'

{
  printf 'Portability audit, %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf 'upstream: %s\n' "$(cat upstream-revision)"
  printf 'host: %s; %s\n' "$(uname -sm)" "$(sw_vers -productVersion 2>/dev/null || true)"
  printf 'toolchain: %s; %s\n' "$(rustc --version)" "$(cargo --version)"
  printf 'xcode: %s\n' "$(xcodebuild -version | tr '\n' ' ')"
  printf 'MACOSX_DEPLOYMENT_TARGET=%s\n\n' "$MACOSX_DEPLOYMENT_TARGET"
} > "$summary"

for target in aarch64-apple-darwin x86_64-apple-darwin; do
  log="$out/build-$target.log"
  cargo build --locked --release --target "$target" \
    -p gliff-client-core -p gliff-mac-core > "$log" 2>&1 \
    || { cat "$log" >&2; printf 'Build failed for %s\n' "$target" >&2; exit 1; }
  tree="$out/tree-$target.txt"
  cargo tree --locked --target "$target" -e normal,build \
    -p gliff-client-core -p gliff-mac-core > "$tree"
  names="$out/crates-$target.txt"
  sed -E 's/^[^a-zA-Z0-9]*//' "$tree" | awk '{print $1}' | grep -v '^$' | sort -u > "$names"
  if grep -E "$forbidden" "$names" > "$out/forbidden-$target.txt"; then
    cat "$out/forbidden-$target.txt" >&2
    printf 'Linux stack crates resolved for %s\n' "$target" >&2
    exit 1
  fi
  lib="target/$target/release/libgliff_mac_core.a"
  dylib="target/$target/release/libgliff_mac_core.dylib"
  {
    printf '== %s ==\n' "$target"
    printf 'build: ok (%s)\n' "$(tail -1 "$log" | sed 's/^ *//')"
    printf 'resolved crates (normal+build): %s, none forbidden\n' "$(wc -l < "$names" | tr -d ' ')"
    printf 'upstream crates: %s\n' "$(grep -E '^gliff-(proto|transport)$' "$names" | tr '\n' ' ')"
    printf 'staticlib: %s\n' "$(lipo -info "$lib" | sed 's/.*: //')"
    printf 'dylib: %s\n' "$(lipo -info "$dylib" | sed 's/.*: //')"
    vtool -show-build "$dylib" | grep -E 'minos|sdk' | sed 's/^ */  /'
    printf '\n'
  } >> "$summary"
done
cat "$summary"
