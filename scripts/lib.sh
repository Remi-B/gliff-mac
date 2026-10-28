#!/usr/bin/env bash

GLIFF_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    printf 'Missing required tool: %s. See docs/development.md.\n' "$1" >&2
    exit 1
  fi
}

require_macos() {
  if [[ "$(uname -s)" != Darwin ]]; then
    printf 'This command requires macOS and the full Xcode installation.\n' >&2
    exit 1
  fi
  require_command xcodebuild
  require_command swift
}
