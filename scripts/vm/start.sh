#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/lib.sh"

if [[ -f "$GLIFF_VM_DIR/qemu.pid" ]] && kill -0 "$(cat "$GLIFF_VM_DIR/qemu.pid")" 2>/dev/null; then
  printf 'VM is already running; use scripts/vm/qmp.py status.\n'
  exit 0
fi
if [[ ! -r /dev/kvm || ! -w /dev/kvm ]]; then
  printf 'This user needs read/write access to /dev/kvm.\n' >&2
  exit 1
fi
for file in OSX-KVM/OVMF_CODE_4M.fd OSX-KVM/OpenCore/OpenCore.qcow2 OVMF_VARS.fd macos.qcow2; do
  [[ -f "$GLIFF_VM_DIR/$file" ]] || { printf 'Missing VM file: %s\n' "$file" >&2; exit 1; }
done
mkdir -p "$GLIFF_VM_DIR/logs"
chmod 700 "$GLIFF_VM_DIR"

# Use the same Apple SMC integration value as the pinned upstream launch script.
# Keep third-party bootloader assets and machine state outside the application repo.
smc_value="$(python3 - "$GLIFF_VM_DIR/OSX-KVM/OpenCore-Boot.sh" <<'PY'
from pathlib import Path
import re
import sys
source = Path(sys.argv[1]).read_text()
print(re.search(r'isa-applesmc,osk="([^"]+)"', source).group(1))
PY
)"

args=(
  -name gliff-macos-builder
  -machine q35,accel=kvm
  -m "${GLIFF_VM_MEMORY_MIB:-8192}"
  -smp "${GLIFF_VM_VCPUS:-4},sockets=1,cores=${GLIFF_VM_VCPUS:-4},threads=1"
  -cpu Skylake-Client,kvm=on,vendor=GenuineIntel,+invtsc,vmware-cpuid-freq=on,-hle,-rtm,+aes,+xsave,+xsaveopt
  -device qemu-xhci,id=xhci
  -device usb-kbd,bus=xhci.0
  -device usb-tablet,bus=xhci.0
  -device isa-applesmc,osk="$smc_value"
  -drive "if=pflash,format=raw,readonly=on,file=$GLIFF_VM_DIR/OSX-KVM/OVMF_CODE_4M.fd"
  -drive "if=pflash,format=raw,file=$GLIFF_VM_DIR/OVMF_VARS.fd"
  -smbios type=2
  -device ich9-ahci,id=sata
  -drive "id=OpenCoreBoot,if=none,snapshot=on,format=qcow2,file=$GLIFF_VM_DIR/OSX-KVM/OpenCore/OpenCore.qcow2"
  -device ide-hd,bus=sata.2,drive=OpenCoreBoot
  -drive "id=MacHDD,if=none,format=qcow2,discard=unmap,file=$GLIFF_VM_DIR/macos.qcow2"
  -device ide-hd,bus=sata.4,drive=MacHDD
  -netdev user,id=net0,hostfwd=tcp:127.0.0.1:2222-:22
  -device virtio-net-pci,netdev=net0,mac=52:54:00:47:4c:46
  -device vmware-svga
  -display none
  -vnc 127.0.0.1:9,websocket=127.0.0.1:6080
  -monitor none
  -qmp "unix:$GLIFF_VM_DIR/qmp.sock,server=on,wait=off"
  -serial "file:$GLIFF_VM_DIR/logs/serial.log"
  -pidfile "$GLIFF_VM_DIR/qemu.pid"
  -daemonize
)
case "${1:-}" in
  --install)
    [[ -f "$GLIFF_VM_DIR/BaseSystem.img" ]] || { printf 'Missing recovery image.\n' >&2; exit 1; }
    args+=(-drive "id=InstallMedia,if=none,format=raw,snapshot=on,file=$GLIFF_VM_DIR/BaseSystem.img")
    args+=(-device ide-hd,bus=sata.3,drive=InstallMedia)
    ;;
  '') ;;
  *) printf 'Usage: %s [--install]\n' "$0" >&2; exit 1 ;;
esac
if ! vm_qemu qemu-system-x86_64 "${args[@]}" 2>>"$GLIFF_VM_DIR/logs/qemu.log"; then
  tail -n 20 "$GLIFF_VM_DIR/logs/qemu.log" >&2
  exit 1
fi
printf 'VM started. SSH: localhost:2222; VNC: localhost:5909; WebSocket: localhost:6080.\n'
