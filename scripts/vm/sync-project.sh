#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/lib.sh"

guest_user="${GLIFF_VM_USER:-builder}"
[[ "$guest_user" =~ ^[a-z_][a-z0-9_-]*$ ]] || { printf 'Invalid guest username.\n' >&2; exit 1; }
ssh_options=(
  -i "$GLIFF_VM_DIR/id_ed25519" -p 2222
  -o BatchMode=yes -o StrictHostKeyChecking=accept-new
  -o "UserKnownHostsFile=$GLIFF_VM_DIR/known_hosts" -o ConnectTimeout=10
)
destination="$guest_user@127.0.0.1"
printf -v rsync_shell '%q ' ssh "${ssh_options[@]}"
ssh "${ssh_options[@]}" "$destination" 'mkdir -p "$HOME/Shared" "$HOME/Projects"'

# Carry local commits without requiring them to be pushed first.
bundle="$GLIFF_VM_DIR/gliff-source.bundle"
git -C "$GLIFF_VM_ROOT" bundle create "$bundle" HEAD
rsync --partial -e "$rsync_shell" -- "$bundle" "$destination:Shared/gliff-source.bundle"
ssh "${ssh_options[@]}" "$destination" /bin/bash -s <<'GUEST'
set -euo pipefail
repo="$HOME/Projects/gliff-mac"
if [[ -e "$repo" && ! -f "$repo/.git/gliff-build-managed" ]]; then
  printf 'Refusing to replace an unmanaged guest checkout: %s\n' "$repo" >&2
  exit 1
fi
if [[ ! -d "$repo" ]]; then
  git clone "$HOME/Shared/gliff-source.bundle" "$repo"
  touch "$repo/.git/gliff-build-managed"
fi
cd "$repo"
git fetch "$HOME/Shared/gliff-source.bundle" HEAD
git reset --hard FETCH_HEAD
git submodule update --init --recursive --checkout
GUEST

# Overlay current working source, preserving guest Git metadata and native caches.
# No --delete-excluded: excluded .git files/directories must remain intact.
rsync -a --delete -e "$rsync_shell" \
  --exclude=.git --exclude=/target/ --exclude=/build/ \
  --exclude=.build --exclude=.swiftpm --exclude=DerivedData --exclude=.DS_Store \
  -- "$GLIFF_VM_ROOT/" "$destination:Projects/gliff-mac/"
printf 'Working source and local commit history synchronized to ~/Projects/gliff-mac in the VM.\n'
