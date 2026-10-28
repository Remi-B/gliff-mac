#!/usr/bin/env python3
"""Prepare credentials for a NEW local build guest; never print secret values."""

import os
from pathlib import Path
import secrets
import shlex
import subprocess

state = Path(os.environ.get("GLIFF_VM_DIR", str(Path.home() / ".local/share/gliff-mac-vm")))
state.mkdir(parents=True, exist_ok=True)
state.chmod(0o700)
key = state / "id_ed25519"
if not key.exists():
    subprocess.run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "",
                    "-C", "gliff-local-build-vm", "-f", str(key)], check=True)
key.chmod(0o600)
public = key.with_suffix(".pub").read_text().strip()
if not public.startswith("ssh-ed25519 ") or "\n" in public:
    raise SystemExit("Unexpected public key format")
password = state / "builder-password"
if not password.exists():
    descriptor = os.open(password, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, "w") as stream:
        stream.write(secrets.token_hex(16) + "\n")
password.chmod(0o600)
bootstrap = state / "bootstrap-public"
bootstrap.mkdir(exist_ok=True)
script = '''#!/bin/bash
set -eu
mkdir -p "$HOME/Shared" "$HOME/.ssh"
chmod 700 "$HOME/.ssh"
touch "$HOME/.ssh/authorized_keys"
chmod 600 "$HOME/.ssh/authorized_keys"
if ! grep -qxF PUBLIC_KEY "$HOME/.ssh/authorized_keys"; then
  printf '%s\\n' PUBLIC_KEY >> "$HOME/.ssh/authorized_keys"
fi
if launchctl print system/com.openssh.sshd >/dev/null 2>&1; then
  sudo launchctl enable system/com.openssh.sshd
else
  sudo launchctl load -w /System/Library/LaunchDaemons/ssh.plist
fi
sudo /usr/sbin/systemsetup -settimezone Europe/Paris
sudo /usr/bin/pmset -a sleep 0 displaysleep 0 disksleep 0
sudo /usr/sbin/scutil --set ComputerName 'Gliff macOS Builder'
sudo /usr/sbin/scutil --set LocalHostName gliff-macos-builder
sudo /usr/sbin/scutil --set HostName gliff-macos-builder
printf 'Shared directory and build SSH access configured.\\n'
'''.replace("PUBLIC_KEY", shlex.quote(public))
(bootstrap / "guest-setup.sh").write_text(script)
print("New-guest access files prepared. Existing keys/password preserved; secret values were not printed.")
