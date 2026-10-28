#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/lib.sh"
[[ -f "$GLIFF_VM_DIR/noVNC/vnc.html" ]] || { printf 'Prepare noVNC with prepare-media.py first.\n' >&2; exit 1; }
if ! systemctl --user is-active --quiet gliff-mac-console.service; then
  systemd-run --user --unit=gliff-mac-console --collect \
    --property=Restart=on-failure \
    /usr/bin/python3 -m http.server 6090 --bind 127.0.0.1 \
    --directory "$GLIFF_VM_DIR/noVNC"
fi
for attempt in {1..10}; do
  if curl -fsS --max-time 1 -o /dev/null http://127.0.0.1:6090/vnc.html; then
    printf 'http://127.0.0.1:6090/vnc.html?host=127.0.0.1&port=6080&autoconnect=1&resize=scale&encrypt=0\n'
    exit 0
  fi
  sleep 0.2
done
printf 'Console service did not become ready; inspect systemctl --user status gliff-mac-console.\n' >&2
exit 1
