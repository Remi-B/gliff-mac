#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/lib.sh"
"$GLIFF_VM_ROOT/scripts/vm/sync-project.sh"

guest_user="${GLIFF_VM_USER:-builder}"
[[ "$guest_user" =~ ^[a-z_][a-z0-9_-]*$ ]] || { printf 'Invalid guest username.\n' >&2; exit 1; }
ssh -i "$GLIFF_VM_DIR/id_ed25519" -p 2222 \
  -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
  -o "UserKnownHostsFile=$GLIFF_VM_DIR/known_hosts" -o ConnectTimeout=10 \
  "$guest_user@127.0.0.1" /bin/bash -s <<'GUEST'
set -euo pipefail
export PATH="$HOME/.cargo/bin:$PATH"
if [[ "$(/usr/bin/xcodebuild -version | head -n 1)" != 'Xcode 16.4' ]]; then
  printf 'The VM needs full Xcode 16.4 selected before building.\n' >&2
  exit 1
fi
if ! command -v rustup >/dev/null 2>&1; then
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs -o "$HOME/Shared/rustup-init.sh"
  sh "$HOME/Shared/rustup-init.sh" -y --no-modify-path --profile minimal --default-toolchain 1.90.0
fi
cd "$HOME/Projects/gliff-mac"
scripts/bootstrap.sh
scripts/check.sh
GUEST
