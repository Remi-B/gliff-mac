#!/usr/bin/env bash
# Run INSIDE the macOS VM after share-xcode.sh has transferred the Apple archive.
set -euo pipefail

[[ "$(uname -s)" == Darwin ]] || { printf 'Run this script inside macOS.\n' >&2; exit 1; }
archive="${1:-$HOME/Shared/Xcode_16.4.xip}"
destination=/Applications/Xcode_16.4.app

app_version() {
  /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$1/Contents/Info.plist"
}

if [[ -d "$destination" ]]; then
  [[ "$(app_version "$destination")" == 16.4 ]] || { printf 'Unexpected existing Xcode version.\n' >&2; exit 1; }
else
  [[ -f "$archive" ]] || { printf 'Missing Apple archive: %s\n' "$archive" >&2; exit 1; }
  archive="$(cd "$(dirname "$archive")" && pwd)/$(basename "$archive")"
  /usr/sbin/pkgutil --check-signature "$archive"
  mkdir -p "$HOME/Shared"
  extraction="$(mktemp -d "$HOME/Shared/xcode-install.XXXXXX")"
  # Keep Apple's signature checks enabled during expansion as well.
  (cd "$extraction" && /usr/bin/xip --expand "$archive")
  [[ "$(app_version "$extraction/Xcode.app")" == 16.4 ]] || {
    printf 'Expanded archive is not Xcode 16.4; refusing to select it.\n' >&2
    exit 1
  }
  mv "$extraction/Xcode.app" "$destination"
  rmdir "$extraction"
fi

/usr/bin/codesign --verify --deep --strict -R='anchor apple' "$destination"
sudo /usr/bin/xcode-select --switch "$destination/Contents/Developer"
sudo /usr/bin/xcodebuild -license accept
sudo /usr/bin/xcodebuild -runFirstLaunch
/usr/bin/sw_vers
/usr/bin/xcode-select -p
/usr/bin/xcodebuild -version
/usr/bin/xcrun swift --version
/usr/bin/xcodebuild -showsdks
