#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/lib.sh"
guest_user="${GLIFF_VM_USER:-builder}"
[[ "$guest_user" =~ ^[a-z_][a-z0-9_-]*$ ]] || { printf 'Invalid guest username.\n' >&2; exit 1; }
exec ssh -i "$GLIFF_VM_DIR/id_ed25519" -p 2222 \
  -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
  -o "UserKnownHostsFile=$GLIFF_VM_DIR/known_hosts" -o ConnectTimeout=10 \
  -o ServerAliveInterval=15 -o ServerAliveCountMax=3 \
  "$guest_user@127.0.0.1" "$@"
