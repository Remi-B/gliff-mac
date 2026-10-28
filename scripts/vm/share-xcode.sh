#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/lib.sh"

archive="${1:-}"
if [[ ! -f "$archive" || "$archive" != *.xip ]]; then
  printf 'Usage: %s /path/to/Xcode_16.4.xip\n' "$0" >&2
  exit 1
fi
archive="$(realpath -- "$archive")"
guest_user="${GLIFF_VM_USER:-builder}"
[[ "$guest_user" =~ ^[a-z_][a-z0-9_-]*$ ]] || { printf 'Invalid guest username.\n' >&2; exit 1; }
ssh_options=(
  -i "$GLIFF_VM_DIR/id_ed25519"
  -p 2222
  -o BatchMode=yes
  -o StrictHostKeyChecking=accept-new
  -o "UserKnownHostsFile=$GLIFF_VM_DIR/known_hosts"
  -o ConnectTimeout=10
)
destination="$guest_user@127.0.0.1"
ssh "${ssh_options[@]}" "$destination" 'mkdir -p "$HOME/Shared"'
# Use a fixed guest filename so remote-shell arguments never contain local paths.
printf -v rsync_shell '%q ' ssh "${ssh_options[@]}"
rsync --partial --progress -e "$rsync_shell" -- \
  "$archive" "$destination:Shared/Xcode_16.4.xip"
local_hash="$(sha256sum "$archive" | cut -d ' ' -f 1)"
remote_hash="$(ssh "${ssh_options[@]}" "$destination" 'shasum -a 256 "$HOME/Shared/Xcode_16.4.xip"' | cut -d ' ' -f 1)"
if [[ "$local_hash" != "$remote_hash" ]]; then
  printf 'Archive checksum mismatch; do not install this transfer.\n' >&2
  exit 1
fi
ssh "${ssh_options[@]}" "$destination" \
  'cat > "$HOME/Shared/install-xcode.sh"; chmod 700 "$HOME/Shared/install-xcode.sh"' \
  < "$GLIFF_VM_ROOT/scripts/vm/install-xcode.sh"
printf 'Verified archive available in the VM at ~/Shared/Xcode_16.4.xip.\n'
printf 'In the VM, run: bash ~/Shared/install-xcode.sh\n'
