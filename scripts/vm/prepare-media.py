#!/usr/bin/env python3
"""Prepare pinned boot assets and a verified Apple recovery image, without root."""

import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

STATE = Path(os.environ.get("GLIFF_VM_DIR", str(Path.home() / ".local/share/gliff-mac-vm")))
OSX_KVM = "4c378a4b5e0b219783683012bec680325eb40719"
NOVNC = "a8dfd6a3ea3c74244f5ebdaa5a7f1023007a7820"


def checkout(url, path, revision):
    if not path.exists():
        path.mkdir(parents=True)
        subprocess.run(["git", "init", str(path)], check=True)
        subprocess.run(["git", "-C", str(path), "remote", "add", "origin", url], check=True)
        subprocess.run(["git", "-C", str(path), "fetch", "--depth", "1", "origin", revision], check=True)
        subprocess.run(["git", "-C", str(path), "checkout", "--detach", "FETCH_HEAD"], check=True)
    actual = subprocess.check_output(["git", "-C", str(path), "rev-parse", "HEAD"], text=True).strip()
    if actual != revision:
        raise SystemExit("Unexpected boot asset revision in {}; preserve local work before changing it".format(path))


def qemu(*arguments):
    environment = dict(os.environ)
    runtime = STATE / "runtime/usr"
    if (runtime / "bin/qemu-img").exists():
        program = str(runtime / "bin/qemu-img")
        environment["LD_LIBRARY_PATH"] = str(runtime / "lib") + (
            ":" + environment["LD_LIBRARY_PATH"] if environment.get("LD_LIBRARY_PATH") else "")
        environment["QEMU_MODULE_DIR"] = str(runtime / "lib/qemu")
    else:
        program = "qemu-img"
    subprocess.run([program, *arguments], env=environment, check=True)


def main():
    if sys.flags.optimize:
        raise SystemExit("Run without Python optimization; upstream signature checks use assertions")
    STATE.mkdir(parents=True, exist_ok=True)
    STATE.chmod(0o700)
    (STATE / "recovery").mkdir(exist_ok=True)
    checkout("https://github.com/kholia/OSX-KVM.git", STATE / "OSX-KVM", OSX_KVM)
    checkout("https://github.com/novnc/noVNC.git", STATE / "noVNC", NOVNC)
    recovery = STATE / "OSX-KVM/fetch-macOS-v2.py"
    image = STATE / "BaseSystem.dmg"
    chunklist = STATE / "BaseSystem.chunklist"
    if not (image.exists() and chunklist.exists()):
        result = subprocess.run([sys.executable, str(recovery), "-s", "sequoia"], cwd=STATE)
        if result.returncode and not (image.exists() and chunklist.exists()):
            raise SystemExit("Recovery download failed before producing both verification inputs")
    # The pinned downloader's progress display fails without a TTY. Independently
    # consume its complete verification generator: all chunks AND Apple signature.
    spec = importlib.util.spec_from_file_location("macrecovery", recovery)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    count = 0
    with image.open("rb") as stream:
        for length, expected in module.verify_chunklist(str(chunklist)):
            block = stream.read(length)
            if len(block) != length or hashlib.sha256(block).digest() != expected:
                raise SystemExit("Apple recovery image failed chunk verification")
            count += 1
        if stream.read(1):
            raise SystemExit("Recovery image has unexpected trailing data")
    with image.open("rb") as stream:
        digest = hashlib.file_digest(stream, "sha256").hexdigest()
    (STATE / "recovery/verification.json").write_text(json.dumps({
        "image_sha256": digest, "verified_chunks": count,
        "osx_kvm_commit": OSX_KVM, "novnc_commit": NOVNC,
        "verification": "Apple signed chunklist and all SHA-256 image chunks",
    }, indent=2) + "\n")
    raw_image = STATE / "BaseSystem.img"
    marker = STATE / "recovery/converted-image.sha256"
    if not raw_image.exists() or not marker.exists() or marker.read_text().strip() != digest:
        temporary = STATE / "BaseSystem.img.new"
        qemu("convert", "-f", "dmg", "-O", "raw", str(image), str(temporary))
        temporary.replace(raw_image)
        marker.write_text(digest + "\n")
    disk = STATE / "macos.qcow2"
    if not disk.exists():
        qemu("create", "-f", "qcow2", str(disk), "128G")
    variables = STATE / "OVMF_VARS.fd"
    if not variables.exists():
        shutil.copyfile(STATE / "OSX-KVM/OVMF_VARS-1920x1080.fd", variables)
    print("Verified Apple recovery image ({} chunks). Existing guest disk/NVRAM preserved.".format(count))


if __name__ == "__main__":
    main()
