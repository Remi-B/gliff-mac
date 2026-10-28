#!/usr/bin/env bash

GLIFF_VM_DIR="${GLIFF_VM_DIR:-$HOME/.local/share/gliff-mac-vm}"
GLIFF_VM_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

vm_qemu() {
  local program="$1"
  shift
  if [[ -x "$GLIFF_VM_DIR/runtime/usr/bin/$program" ]]; then
    env LD_LIBRARY_PATH="$GLIFF_VM_DIR/runtime/usr/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
      QEMU_MODULE_DIR="$GLIFF_VM_DIR/runtime/usr/lib/qemu" \
      "$GLIFF_VM_DIR/runtime/usr/bin/$program" "$@"
  else
    command "$program" "$@"
  fi
}
