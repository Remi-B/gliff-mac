#!/usr/bin/env python3
"""Run the app's compatibility gates and report each as passed, failed or unavailable.

`scripts/check.sh` runs every gate this host can run. A gate this host cannot
run (Apple builds on Linux, the separate upstream Linux workspace outside its CI
job, live-host evidence that was not supplied) and a gate whose feature is not
implemented yet are reported as unavailable with the reason; neither is ever
reported as passed. The command fails when a gate fails. Whether a candidate is
qualified is decided by `scripts/upstream.py qualify` over the summaries of every
platform, because a single host never runs all required gates.

usage: gates.py [--only ID,...] [--upstream-linux] [--live-evidence FILE]...
                [--summary FILE] [--list]
"""

import argparse
import datetime
import json
import os
from pathlib import Path
import platform
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parent.parent
MAC = platform.system() == "Darwin"
FIXTURE_GEN = "tools/fixture-gen/Cargo.toml"
UPSTREAM = "vendor/gliff/Cargo.toml"
APPLE_ENV = {"MACOSX_DEPLOYMENT_TARGET": "13.0"}

# id, title, required for qualification, availability, commands.
# Availability is "all", "macos", "upstream-linux", "live" or "planned:<task>".
# A planned gate becomes "all"/"macos" (and required) in the task that
# implements its feature; until then it is reported unavailable, not passed.
GATES = [
    ("structure", "Pinned source, clean submodule and app workspace", True, "all",
     [["python3", "scripts/check-structure.py"]]),
    ("compatibility-records", "Compatibility records match the pin and lockfiles", True, "all",
     [["python3", "scripts/upstream.py", "check"]]),
    ("protocol-surface", "Pinned wire surface matches the reviewed record", True, "all",
     [["cargo", "test", "--locked", "-p", "gliff-client-core", "--test", "protocol_surface"]]),
    ("rust-format", "rustfmt (app and fixture tool)", True, "all",
     [["cargo", "fmt", "--all", "--check"],
      ["cargo", "fmt", "--manifest-path", FIXTURE_GEN, "--check"]]),
    ("rust-lint", "Clippy (app and fixture tool)", True, "all",
     [["cargo", "clippy", "--workspace", "--all-targets", "--locked", "--", "-D", "warnings"],
      ["cargo", "clippy", "--manifest-path", FIXTURE_GEN, "--all-targets", "--locked", "--",
       "-D", "warnings"]]),
    ("rust-tests", "Unit, mock peer and contract replay tests", True, "all",
     [["cargo", "test", "--workspace", "--locked"],
      ["cargo", "test", "--manifest-path", FIXTURE_GEN, "--locked"]]),
    ("contract-fixtures", "Task 02 fixtures replay and match their manifests", True, "all",
     [["scripts/generate-fixtures.sh", "--check"]]),
    ("whitespace", "No whitespace errors in the working tree", True, "all",
     [["git", "diff", "--check"]]),
    ("apple-rust-arm64", "Rust check for aarch64-apple-darwin", True, "macos",
     [["cargo", "check", "--workspace", "--all-targets", "--locked", "--target",
       "aarch64-apple-darwin"]]),
    ("apple-rust-x86_64", "Rust check for x86_64-apple-darwin", True, "macos",
     [["cargo", "check", "--workspace", "--all-targets", "--locked", "--target",
       "x86_64-apple-darwin"]]),
    ("portability-audit", "Release builds and dependency audit for both Apple targets", True,
     "macos", [["scripts/audit-portability.sh"]]),
    ("swift-package", "GliffCore Swift package builds", True, "macos",
     [["swift", "build", "--package-path", "macos/Packages/GliffCore"]]),
    ("macos-app", "Universal Xcode app build (arm64 + x86_64)", True, "macos",
     [["scripts/build-app.sh"]]),
    ("upstream-linux", "Upstream workspace fmt/clippy/tests with its own lockfile", True,
     "upstream-linux",
     [["cargo", "fmt", "--manifest-path", UPSTREAM, "--all", "--check"],
      ["cargo", "clippy", "--manifest-path", UPSTREAM, "--workspace", "--all-targets",
       "--locked", "--", "-D", "warnings"],
      ["cargo", "test", "--manifest-path", UPSTREAM, "--workspace", "--locked"]]),
    ("live-host", "Live session against the unmodified server on Linux/Hyprland", True, "live",
     []),
    ("bridge-import", "Generated Swift bindings import and callback smoke test", False,
     "planned:04", []),
    ("ssh-session", "Real SSH session handshake, acknowledgments and cancellation", False,
     "planned:05", []),
    ("video-decode", "VideoToolbox Single420 decode against fixtures", False, "planned:07", []),
    ("metal-chroma", "Dual420 Metal recombination against the reference", False, "planned:08",
     []),
    ("remote-input", "Keyboard/pointer mapping and escape shortcut", False, "planned:09", []),
    ("displays-reconnect", "Mirror/headless, resize and reconnection", False, "planned:10", []),
    ("clipboard", "Shared clipboard transfers and isolation", False, "planned:11", []),
    ("acceptance", "Cross-platform acceptance matrix and measurements", False, "planned:12",
     []),
]


def git(*args):
    return subprocess.run(["git", *args], cwd=ROOT, text=True, capture_output=True).stdout.strip()


def tool_version(*command):
    try:
        return subprocess.run(command, cwd=ROOT, text=True, capture_output=True,
                              check=True).stdout.strip().splitlines()[0]
    except (OSError, subprocess.CalledProcessError, IndexError):
        return None


def context():
    machine = platform.machine()
    return {
        "os": "macOS " + platform.mac_ver()[0] if MAC else
              "{} {}".format(platform.system(), platform.release()),
        "arch": "arm64" if machine in ("arm64", "aarch64") else machine,
        "client_source_sha": git("rev-parse", "HEAD"),
        "client_dirty": bool(git("status", "--porcelain", "--untracked-files=no")),
        "upstream_sha": (ROOT / "upstream-revision").read_text().strip(),
        "rustc": tool_version("rustc", "--version"),
        "xcode": " ".join(subprocess.run(["xcodebuild", "-version"], text=True,
                                         capture_output=True).stdout.split()[:2]) if MAC else None,
        "date": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    }


def live_result(files):
    if not files:
        return "unavailable", ("no live-host evidence supplied; run scripts/live-host-check.sh "
                               "HOST and pass --live-evidence build/live/<run>/evidence.json")
    pin = (ROOT / "upstream-revision").read_text().strip()
    reasons = []
    for path in files:
        evidence = json.loads(Path(path).read_text())
        if evidence.get("server", {}).get("source_sha") != pin:
            return "failed", "{}: server source {} is not the pinned {}".format(
                path, evidence.get("server", {}).get("source_sha"), pin)
        if evidence.get("status") != "passed":
            return "failed", "{}: {}".format(path, evidence.get("reason") or "failed")
        session = evidence["session"]
        reasons.append("{} {} {} frames decoded from {} ({})".format(
            session["chroma"], evidence["server"]["arguments"][3],
            session["frames_decoded"], evidence["server"]["host"], evidence["date"]))
    return "passed", "; ".join(reasons)


def run_gate(gate, args, log_dir):
    gate_id, title, required, availability, commands = gate
    result = {"id": gate_id, "title": title, "required": required}
    if availability == "macos" and not MAC:
        return {**result, "status": "unavailable", "reason": "requires macOS with Xcode"}
    if availability == "upstream-linux" and not args.upstream_linux:
        return {**result, "status": "unavailable",
                "reason": "runs in the separate upstream-linux CI job (--upstream-linux)"}
    if availability.startswith("planned:"):
        task = availability.split(":")[1]
        return {**result, "status": "unavailable",
                "reason": "planned in task {}; not implemented yet".format(task)}
    if availability == "live":
        status, reason = live_result(args.live_evidence)
        return {**result, "status": status, "reason": reason}
    log = log_dir / "{}.log".format(gate_id)
    started = time.monotonic()
    env = {**os.environ, **(APPLE_ENV if availability == "macos" else {})}
    with log.open("w") as handle:
        for command in commands:
            handle.write("$ {}\n".format(" ".join(command)))
            handle.flush()
            print("[{}] {}".format(gate_id, " ".join(command)), flush=True)
            code = subprocess.run(command, cwd=ROOT, env=env, stdout=handle,
                                  stderr=subprocess.STDOUT).returncode
            if code != 0:
                tail = log.read_text().splitlines()[-40:]
                print("\n".join(tail), file=sys.stderr)
                return {**result, "status": "failed", "seconds": round(time.monotonic() - started),
                        "reason": "`{}` exited with {}; log: {}".format(
                            " ".join(command), code, log.relative_to(ROOT)),
                        "log_tail": tail}
    return {**result, "status": "passed", "seconds": round(time.monotonic() - started)}


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--only", help="comma-separated gate ids")
    parser.add_argument("--upstream-linux", action="store_true",
                        help="run upstream's own workspace checks (Linux with its libraries)")
    parser.add_argument("--live-evidence", action="append", default=[],
                        help="evidence.json from scripts/live-host-check.sh")
    parser.add_argument("--summary", help="summary path (default build/gates/<os>-<arch>.json)")
    parser.add_argument("--list", action="store_true", help="list gates and exit")
    args = parser.parse_args()
    if args.list:
        for gate_id, title, required, availability, _ in GATES:
            print("{:22} {:14} {:9} {}".format(gate_id, availability,
                                               "required" if required else "planned", title))
        return 0
    selected = GATES
    if args.only:
        wanted = args.only.split(",")
        unknown = set(wanted) - {gate[0] for gate in GATES}
        if unknown:
            parser.error("unknown gate(s): " + ", ".join(sorted(unknown)))
        selected = [gate for gate in GATES if gate[0] in wanted]

    info = context()
    log_dir = ROOT / "build/gates/logs"
    log_dir.mkdir(parents=True, exist_ok=True)
    results = [run_gate(gate, args, log_dir) for gate in selected]
    summary = {"schema": 1, "context": info, "gates": results}
    path = Path(args.summary) if args.summary else ROOT / "build/gates/{}-{}.json".format(
        "macos" if MAC else platform.system().lower(), info["arch"])
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(summary, indent=2) + "\n")

    width = max(len(r["id"]) for r in results)
    print("\nGate results ({}, {}, upstream {}):".format(info["os"], info["arch"],
                                                      info["upstream_sha"][:12]))
    for r in results:
        print("  {:{w}}  {:11}  {}".format(r["id"], r["status"].upper(), r.get("reason", ""),
                                          w=width))
    counts = {s: sum(r["status"] == s for r in results) for s in ("passed", "failed",
                                                                 "unavailable")}
    print("{passed} passed, {failed} failed, {unavailable} unavailable. Summary: {path}".format(
        path=path.relative_to(ROOT) if path.is_relative_to(ROOT) else path, **counts))
    return 1 if counts["failed"] else 0


if __name__ == "__main__":
    sys.exit(main())
