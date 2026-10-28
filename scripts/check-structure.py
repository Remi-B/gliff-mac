#!/usr/bin/env python3
"""Validate the source pin and independent Cargo workspace without Apple tools."""

import json
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent


def output(*args):
    return subprocess.check_output(args, cwd=ROOT, text=True).strip()


def require(condition, message):
    if not condition:
        raise SystemExit(message)


def main():
    pin = (ROOT / "upstream-revision").read_text().strip()
    require(re.fullmatch(r"[0-9a-f]{40}", pin), "Invalid upstream-revision SHA")
    vendor = ROOT / "vendor/gliff"
    require((vendor / ".git").exists(), "Initialize vendor/gliff with scripts/bootstrap.sh")
    index = output("git", "ls-files", "--stage", "vendor/gliff").split()
    require(len(index) == 4 and index[:3] == ["160000", pin, "0"],
            "Gitlink and upstream-revision differ; stage the intended pin together")
    require(output("git", "-C", str(vendor), "rev-parse", "HEAD") == pin,
            "vendor/gliff is not at the recorded revision; initialize submodules")
    require(not output("git", "-C", str(vendor), "status", "--porcelain"),
            "vendor/gliff must be unmodified")
    require(output("git", "config", "-f", ".gitmodules", "--get",
                   "submodule.vendor/gliff.url") == "https://github.com/omacom/gliff.git",
            "Unexpected upstream URL; document any intentional fork before changing it")

    metadata = json.loads(output("cargo", "metadata", "--format-version", "1", "--locked"))
    packages = {package["id"]: package for package in metadata["packages"]}
    members = {packages[item]["name"] for item in metadata["workspace_members"]}
    require(members == {"gliff-client-core", "gliff-mac-core", "gliff-uniffi-bindgen"},
            "Only app crates and the generator may be workspace members")
    # The fixture generator's separate workspace links gliff-sw/OpenH264;
    # neither may reach the application graph.
    forbidden = ("gtk", "gdk", "wayland-", "xkbcommon", "hypr-", "gliff-vk", "gliff-va",
                 "gliff-sw", "gliff-server", "openh264", "drm", "gbm", "dbus")
    names = {package["name"] for package in packages.values()}
    require(not any(name.startswith(forbidden) for name in names),
            "Linux UI/video dependencies leaked into the app dependency graph")
    for name in ("gliff-proto", "gliff-transport"):
        manifests = [Path(package["manifest_path"]).resolve()
                     for package in packages.values() if package["name"] == name]
        require(manifests == [(vendor / "crates" / name / "Cargo.toml").resolve()],
                "{} must come from the pinned submodule".format(name))
    require(Path(metadata["workspace_root"]).resolve() == ROOT,
            "Cargo selected the wrong workspace root")
    print("Workspace: 3 app members; upstream: {}; no Linux UI/video stack.".format(pin))


if __name__ == "__main__":
    try:
        main()
    except (subprocess.CalledProcessError, FileNotFoundError) as error:
        print("Structure check failed: {}".format(error), file=sys.stderr)
        sys.exit(1)
