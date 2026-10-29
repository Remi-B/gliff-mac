#!/usr/bin/env python3
"""Upstream pin maintenance: discover, update, check, report, record and qualify.

Normal builds never move the pin. An update needs an explicit full commit SHA
from the trusted upstream repository, stages the gitlink, `upstream-revision`,
any lockfile refresh and an unqualified candidate record together, and writes a
focused review report. Roll back by reverting that parent commit and running
`git submodule update --init --recursive`; see
docs/03-automate-upstream-sync-and-compatibility/upstream-update-workflow.md.

  upstream.py status [--sha SHA] [--no-fetch] [--github-output]
  upstream.py update SHA [--allow-stale] [--no-fetch] [--report FILE]
  upstream.py abort
  upstream.py check
  upstream.py report OLD NEW [--out FILE]
  upstream.py record ROLE --gates FILE... [--live-evidence FILE]...
  upstream.py qualify --gates FILE... [--live-evidence FILE]... [--markdown FILE]
  upstream.py cache-key TARGET
"""

import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent
VENDOR = ROOT / "vendor/gliff"
MATRIX = ROOT / "tests/compatibility/matrix.json"
SURFACE = ROOT / "tests/compatibility/protocol-surface.json"
TEMPLATE = ROOT / "tests/compatibility/update-report-template.md"
UPSTREAM_URL = "https://github.com/omacom/gliff.git"
UPSTREAM_BRANCH = "main"
LOCKFILES = ("Cargo.lock", "tools/fixture-gen/Cargo.lock")
ROLES = ("initial-release", "current-pin", "candidate")

# Upstream paths whose changes the update report calls out for review, by
# area. A file may belong to several areas.
AREAS = [
    ("Protocol (wire types, framing, features)",
     ("crates/gliff-proto/src/msg.rs", "crates/gliff-proto/src/frame.rs",
      "crates/gliff-proto/src/cbor.rs", "crates/gliff-proto/src/lib.rs")),
    ("Transport (framed I/O, SSH spawning)",
     ("crates/gliff-transport/src/lib.rs", "crates/gliff-transport/src/ssh.rs")),
    ("Session behaviour (handshake, acks, pacing, streams)",
     ("crates/gliff/src/net.rs", "crates/gliff-server/src/session.rs",
      "crates/gliff-server/src/writer.rs", "crates/gliff-server/src/rate.rs",
      "crates/gliff-server/src/main.rs")),
    ("Input and keymaps",
     ("crates/hypr-input/", "crates/gliff/src/keymap.rs")),
    ("Clipboard",
     ("crates/gliff-proto/src/clipboard.rs", "crates/gliff-transport/src/clipboard/",
      "crates/gliff-server/src/clipboard.rs", "crates/gliff/src/clipboard",
      "crates/hypr-input/src/clipboard.rs")),
    ("Colour and chroma reference",
     ("crates/gliff-proto/src/chroma.rs", "crates/gliff-proto/src/color.rs",
      "crates/gliff-sw/src/convert.rs", "crates/gliff-vk/src/compute.rs",
      "crates/gliff-vk/shaders/")),
    ("Manifests, lockfile and toolchain",
     ("Cargo.toml", "Cargo.lock", "rust-toolchain", "crates/gliff-proto/Cargo.toml",
      "crates/gliff-transport/Cargo.toml", ".gitmodules")),
]
APP_GRAPH = ("crates/gliff-proto/", "crates/gliff-transport/", "Cargo.toml")


def run(*args, cwd=ROOT, check=True, env=None):
    result = subprocess.run(args, cwd=cwd, text=True, capture_output=True,
                            env={**os.environ, **(env or {})})
    if check and result.returncode != 0:
        raise SystemExit("{} failed:\n{}".format(" ".join(args), result.stderr.strip()))
    return result.stdout.strip()


def vgit(*args, check=True):
    return run("git", "-C", str(VENDOR), *args, check=check)


def sha256(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def pin():
    return (ROOT / "upstream-revision").read_text().strip()


def now():
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def require_sha(value):
    if not re.fullmatch(r"[0-9a-f]{40}", value or ""):
        raise SystemExit("An explicit full 40-character lowercase commit SHA is required, "
                         "not {!r}. Branches and tags are never pinned.".format(value))
    return value


def fetch():
    url = run("git", "config", "-f", ".gitmodules", "--get", "submodule.vendor/gliff.url")
    if url != UPSTREAM_URL:
        raise SystemExit("Unexpected upstream URL {}; document an intentional fork first".format(url))
    vgit("fetch", "--quiet", "--tags", url,
         "+refs/heads/{0}:refs/remotes/origin/{0}".format(UPSTREAM_BRANCH))


def describe(sha):
    return vgit("describe", "--tags", "--always", sha, check=False) or sha[:12]


def is_ancestor(a, b):
    return subprocess.run(["git", "-C", str(VENDOR), "merge-base", "--is-ancestor", a, b]
                          ).returncode == 0


def relation(old, new):
    """How a candidate relates to the pin: same, upgrade, stale or diverged."""
    if old == new:
        return "same"
    if is_ancestor(old, new):
        return "upgrade"
    if is_ancestor(new, old):
        return "stale"
    return "diverged"


def trusted(sha):
    """The commit is on upstream main or on a release tag of the trusted repository."""
    if vgit("cat-file", "-t", sha, check=False) != "commit":
        return False
    if is_ancestor(sha, "refs/remotes/origin/" + UPSTREAM_BRANCH):
        return True
    return bool(vgit("tag", "--contains", sha, "--list", "v*", check=False))


def require_clean():
    dirty = run("git", "status", "--porcelain", "--untracked-files=no")
    if dirty:
        raise SystemExit("The parent checkout has uncommitted changes:\n{}".format(dirty))
    run("python3", "scripts/check-structure.py")


def protocol_summary():
    surface = json.loads(SURFACE.read_text())
    return {"version": surface["protocol_version"], "features": surface["features"],
            "surface_sha256": sha256(SURFACE)}


# --- status -------------------------------------------------------------------


def cmd_status(args):
    if not args.no_fetch:
        fetch()
    current = pin()
    tip = vgit("rev-parse", "refs/remotes/origin/" + UPSTREAM_BRANCH)
    candidate = require_sha(args.sha) if args.sha else tip
    if not trusted(candidate):
        raise SystemExit("{} is not on upstream {} or a release tag".format(candidate,
                                                                           UPSTREAM_BRANCH))
    kind = relation(current, candidate)
    ahead = int(vgit("rev-list", "--count", "{}..{}".format(current, candidate)))
    print("pin:       {} ({})".format(current, describe(current)))
    print("upstream:  {} ({})".format(tip, describe(tip)))
    print("candidate: {} ({}), {}, {} new commit(s)".format(candidate, describe(candidate),
                                                           kind, ahead))
    if kind == "same":
        print("No update: the candidate is the current pin.")
    elif kind != "upgrade":
        print("No update: the candidate is not a descendant of the pin ({}).".format(kind))
    if args.github_output:
        with open(os.environ["GITHUB_OUTPUT"], "a") as out:
            out.write("pin={}\ncandidate={}\nrelation={}\nahead={}\nupdate={}\n".format(
                current, candidate, kind, ahead, str(kind == "upgrade").lower()))
    return 0


# --- update / abort ------------------------------------------------------------


def sync_lockfiles():
    """Let Cargo record changed path-dependency versions without unrelated upgrades."""
    for lock in LOCKFILES:
        manifest = str(Path(lock).parent / "Cargo.toml")
        run("cargo", "metadata", "--format-version", "1", "--manifest-path", manifest)
    return [lock for lock in LOCKFILES if run("git", "diff", "--name-only", "--", lock)]


def cmd_update(args):
    candidate = require_sha(args.sha)
    require_clean()
    if not args.no_fetch:
        fetch()
    current = pin()
    if not trusted(candidate):
        raise SystemExit("{} is not on upstream {} or a release tag of {}; only trusted "
                         "upstream commits are pinned".format(candidate, UPSTREAM_BRANCH,
                                                              UPSTREAM_URL))
    kind = relation(current, candidate)
    report = Path(args.report or ROOT / "build/upstream/report-{}-{}.md".format(
        current[:12], candidate[:12]))
    if kind == "same":
        write_report(current, candidate, report)
        print("Candidate equals the current pin {}: rehearsal only, nothing staged. "
              "This is not an upgrade.\nReport: {}".format(describe(current), report))
        return 0
    if kind != "upgrade" and not args.allow_stale:
        raise SystemExit("Candidate {} is {} relative to the pin {}; refusing. Pass "
                         "--allow-stale only to rehearse an older pin in a disposable "
                         "branch.".format(candidate, kind, current))

    vgit("checkout", "--quiet", "--detach", candidate)
    vgit("submodule", "update", "--init", "--recursive", "--checkout")
    (ROOT / "upstream-revision").write_text(candidate + "\n")
    run("git", "add", "vendor/gliff", "upstream-revision")
    changed = sync_lockfiles()
    if changed:
        run("git", "add", *changed)
    matrix = json.loads(MATRIX.read_text())
    matrix["records"]["candidate"] = {
        "role": "candidate",
        "relation": kind,
        "result": "unqualified",
        "reason": "staged; required gates have not run",
        "date": now(),
        "upstream": {"sha": candidate, "describe": describe(candidate),
                     "previous_sha": current,
                     "lockfile_sha256": sha256(VENDOR / "Cargo.lock")},
    }
    MATRIX.write_text(json.dumps(matrix, indent=2) + "\n")
    run("git", "add", str(MATRIX.relative_to(ROOT)))
    write_report(current, candidate, report)
    print("Staged upstream {} -> {} ({}). Lockfiles refreshed: {}.".format(
        describe(current), describe(candidate), kind, ", ".join(changed) or "none"))
    print("Report: {}\nNext: scripts/check.sh, then record the gates; "
          "abort with scripts/upstream.py abort.".format(report))
    return 0


def cmd_abort(_args):
    paths = ["upstream-revision", "vendor/gliff", str(MATRIX.relative_to(ROOT)), *LOCKFILES]
    run("git", "restore", "--staged", "--worktree", "--source=HEAD", "--", *paths)
    run("git", "submodule", "update", "--init", "--recursive", "--checkout", "vendor/gliff")
    run("python3", "scripts/check-structure.py")
    print("Restored the committed pin {} ({}).".format(pin(), describe(pin())))
    return 0


# --- report --------------------------------------------------------------------


def write_report(old, new, path):
    kind = relation(old, new)
    numstat = vgit("diff", "--numstat", "{}..{}".format(old, new)).splitlines() if old != new \
        else []
    files = {}
    for line in numstat:
        added, removed, name = line.split("\t", 2)
        files[name] = (added, removed)
    sections = []
    for title, prefixes in AREAS:
        hits = sorted(name for name in files if name.startswith(prefixes))
        body = "\n".join("- `{}` (+{} −{})".format(n, *files[n]) for n in hits) or "- No change."
        sections.append("### {}\n\n{}".format(title, body))
    others = sorted(n for n in files if not any(n.startswith(p) for _, ps in AREAS for p in ps))
    if others:
        sections.append("### Other paths\n\n" + "\n".join(
            "- `{}` (+{} −{})".format(n, *files[n]) for n in others))
    commits = vgit("log", "--format=- `%h` %s (%an, %as)", "--no-merges",
                   "{}..{}".format(old, new)).splitlines() if kind == "upgrade" else []
    diff = vgit("diff", "{}..{}".format(old, new), "--", "crates/gliff-proto/src/msg.rs") \
        if old != new else ""
    flags = []
    if re.search(r"^[-+]pub const PROTOCOL_VERSION", diff, re.M):
        flags.append("**PROTOCOL_VERSION changed**: breaking wire upgrade.")
    if re.search(r"^[-+]pub const FEATURES", diff, re.M):
        flags.append("Handshake `FEATURES` changed: review new optional behaviour.")
    if re.search(r"^[-+]\s*#\[n\(", diff, re.M):
        flags.append("Message field numbering changed in `msg.rs`: review wire compatibility.")
    if any(n.startswith(APP_GRAPH) for n in files):
        flags.append("Crates in the app graph changed: Rust API review for the adapter.")
    if kind == "same":
        flags.append("Rehearsal: the candidate is the current pin; this is not an upgrade.")
    elif kind != "upgrade":
        flags.append("**Candidate is {} relative to the pin**: not an upgrade.".format(kind))
    values = {
        "old_sha": old, "new_sha": new, "old_describe": describe(old),
        "new_describe": describe(new), "relation": kind, "date": now(),
        "commit_count": str(len(commits)),
        "commits": "\n".join(commits[:100]) or "- None.",
        "flags": "\n".join("- " + f for f in flags) or "- None detected automatically.",
        "areas": "\n\n".join(sections),
        "files_changed": str(len(files)),
    }
    text = TEMPLATE.read_text()
    for key, value in values.items():
        text = text.replace("{{" + key + "}}", value)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)
    return path


def cmd_report(args):
    old, new = require_sha(args.old), require_sha(args.new)
    path = write_report(old, new, Path(args.out or ROOT / "build/upstream/report-{}-{}.md".format(
        old[:12], new[:12])))
    print(path.read_text() if args.out is None else "Report: {}".format(path))
    return 0


# --- qualification and records -------------------------------------------------


def merge_gates(gate_files, live_files):
    """Combine per-platform summaries: a failure anywhere fails the gate; a pass
    needs every summary that could run it to pass; otherwise it is unavailable."""
    summaries = [json.loads(Path(p).read_text()) for p in gate_files]
    merged = {}
    for summary in summaries:
        for gate in summary["gates"]:
            entry = merged.setdefault(gate["id"], {"id": gate["id"], "title": gate["title"],
                                                   "required": gate["required"],
                                                   "status": "unavailable", "platforms": {}})
            where = "{} {}".format(summary["context"]["os"], summary["context"]["arch"])
            entry["platforms"][where] = gate["status"]
            if gate["status"] == "failed":
                entry["status"] = "failed"
                entry["reason"] = "{}: {}".format(where, gate.get("reason"))
            elif gate["status"] == "passed" and entry["status"] != "failed":
                entry["status"] = "passed"
                entry.pop("reason", None)
            elif entry["status"] == "unavailable":
                entry["reason"] = gate.get("reason")
    if live_files:
        sys.path.insert(0, str(ROOT / "scripts"))
        import gates  # noqa: E402  pylint: disable=import-outside-toplevel
        status, reason = gates.live_result(live_files)
        entry = merged.setdefault("live-host", {"id": "live-host", "required": True,
                                                "title": "Live session", "platforms": {}})
        if entry.get("status") != "failed":
            entry["status"], entry["reason"] = status, reason
    required = [g for g in merged.values() if g["required"]]
    failed = [g["id"] for g in required if g["status"] == "failed"]
    missing = [g["id"] for g in required if g["status"] == "unavailable"]
    if failed:
        result, reason = "failed", "required gate(s) failed: " + ", ".join(failed)
    elif missing:
        result, reason = "unqualified", "required gate(s) unavailable: " + ", ".join(missing)
    else:
        result, reason = "qualified", "every required gate passed; human review decides the merge"
    return summaries, merged, result, reason


def gates_markdown(merged, result, reason):
    icon = {"passed": "✅ passed", "failed": "❌ failed", "unavailable": "⚪ unavailable"}
    lines = ["**Result: {}** — {}".format(result, reason), "",
             "| Gate | Required | Status | Platforms / reason |", "| --- | --- | --- | --- |"]
    for gate in merged.values():
        detail = ", ".join("{}: {}".format(k, v) for k, v in gate.get("platforms", {}).items())
        if gate.get("reason") and gate["status"] != "passed":
            detail = gate["reason"] if not detail else detail + " — " + gate["reason"]
        elif gate["id"] == "live-host":
            detail = gate.get("reason", "")
        lines.append("| `{}` | {} | {} | {} |".format(gate["id"],
                                                 "yes" if gate["required"] else "planned",
                                                 icon[gate["status"]],
                                                 detail.replace("|", "\\|")))
    return "\n".join(lines) + "\n"


def cmd_qualify(args):
    _, merged, result, reason = merge_gates(args.gates, args.live_evidence)
    text = gates_markdown(merged, result, reason)
    if args.markdown:
        Path(args.markdown).write_text(text)
    print(text)
    return 1 if result == "failed" else 0


def cmd_record(args):
    summaries, merged, result, reason = merge_gates(args.gates, args.live_evidence)
    current = pin()
    for summary in summaries:
        if summary["context"]["upstream_sha"] != current:
            raise SystemExit("Gate summary for upstream {} does not match the pin {}".format(
                summary["context"]["upstream_sha"], current))
    lives = [json.loads(Path(p).read_text()) for p in args.live_evidence]
    clients = {s["context"]["client_source_sha"] for s in summaries}
    record = {
        "role": args.role,
        "result": result,
        "reason": reason,
        "date": now(),
        "upstream": {"sha": current, "describe": describe(current),
                     "lockfile_sha256": sha256(VENDOR / "Cargo.lock")},
        "client": {"source_shas": sorted(clients),
                   "dirty": any(s["context"]["client_dirty"] for s in summaries),
                   "lockfile_sha256": sha256(ROOT / "Cargo.lock")},
        "protocol": protocol_summary(),
        "platforms": [{"os": s["context"]["os"], "arch": s["context"]["arch"],
                       "rustc": s["context"]["rustc"], "xcode": s["context"]["xcode"],
                       "date": s["context"]["date"]} for s in summaries],
        "servers": [{**live["server"], "date": live["date"], "status": live["status"],
                     "session": live["session"]} for live in lives],
        "gates": {g["id"]: g["status"] for g in merged.values()},
    }
    matrix = json.loads(MATRIX.read_text())
    matrix["records"][args.role] = record
    if args.role == "current-pin":
        candidate = matrix["records"].get("candidate")
        if candidate and candidate["upstream"]["sha"] == current:
            matrix["records"]["candidate"] = None
    MATRIX.write_text(json.dumps(matrix, indent=2) + "\n")
    print("Recorded {}: {} ({}).".format(args.role, result, reason))
    return 0


# --- check ---------------------------------------------------------------------


def cmd_check(_args):
    matrix = json.loads(MATRIX.read_text())
    records = matrix.get("records", {})
    problems = []
    if set(records) != set(ROLES):
        problems.append("records must be exactly: " + ", ".join(ROLES))
    current = pin()
    record = records.get("current-pin")
    candidate = records.get("candidate")
    if candidate and candidate.get("upstream", {}).get("sha") == current:
        record = candidate
    if not record:
        problems.append("no current-pin record")
    else:
        expect = [
            ("upstream.sha", record["upstream"]["sha"], current),
            ("upstream.lockfile_sha256", record["upstream"]["lockfile_sha256"],
             sha256(VENDOR / "Cargo.lock")),
        ]
        if record is not candidate:
            expect += [
                ("client.lockfile_sha256", record["client"]["lockfile_sha256"],
                 sha256(ROOT / "Cargo.lock")),
                ("protocol.surface_sha256", record["protocol"]["surface_sha256"],
                 sha256(SURFACE)),
            ]
        for name, recorded, actual in expect:
            if recorded != actual:
                problems.append("{} record {} = {}, but the checkout has {}".format(
                    record["role"], name, recorded, actual))
    for role, entry in records.items():
        if entry is None:
            continue
        if entry.get("result") not in ("qualified", "unqualified", "failed"):
            problems.append("{}: result must be qualified, unqualified or failed".format(role))
        if entry.get("result") == "qualified" and any(
                status != "passed" for gate, status in entry.get("gates", {}).items()
                if gate in required_gates()):
            problems.append("{}: qualified with a required gate not passed".format(role))
    if problems:
        raise SystemExit("Compatibility records are out of date with the checkout:\n  - " +
                         "\n  - ".join(problems) +
                         "\nAfter an intentional pin, lockfile or wire-surface change, re-run "
                         "the gates and `scripts/upstream.py record current-pin --gates ...`.")
    print("Compatibility records match upstream {} and both lockfiles.".format(current[:12]))
    return 0


def required_gates():
    sys.path.insert(0, str(ROOT / "scripts"))
    import gates  # noqa: E402  pylint: disable=import-outside-toplevel
    return {gate[0] for gate in gates.GATES if gate[2]}


# --- cache key -----------------------------------------------------------------


def cmd_cache_key(args):
    toolchain = re.search(r'^channel = "([^"]+)"', (ROOT / "rust-toolchain.toml").read_text(),
                          re.M).group(1)
    uniffi = re.search(r'^uniffi = \{ version = "=?([^"]+)"', (ROOT / "Cargo.toml").read_text(),
                       re.M).group(1)
    xcode = "none"
    if sys.platform == "darwin":
        xcode = run("xcodebuild", "-version").split()[1]
    locks = hashlib.sha256(b"".join(sha256(ROOT / lock).encode() for lock in LOCKFILES))
    print("gliff-{}-{}-rust{}-uniffi{}-xcode{}-up{}-lock{}".format(
        sys.platform, args.target, toolchain, uniffi, xcode, pin()[:12],
        locks.hexdigest()[:16]))
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = parser.add_subparsers(dest="command", required=True)
    p = sub.add_parser("status", help="compare the pin with upstream")
    p.add_argument("--sha")
    p.add_argument("--no-fetch", action="store_true")
    p.add_argument("--github-output", action="store_true")
    p.set_defaults(func=cmd_status)
    p = sub.add_parser("update", help="stage an exact candidate SHA")
    p.add_argument("sha")
    p.add_argument("--allow-stale", action="store_true",
                   help="rehearse an older or diverged pin (disposable branches only)")
    p.add_argument("--no-fetch", action="store_true")
    p.add_argument("--report")
    p.set_defaults(func=cmd_update)
    p = sub.add_parser("abort", help="restore the committed pin")
    p.set_defaults(func=cmd_abort)
    p = sub.add_parser("check", help="verify compatibility records against the checkout")
    p.set_defaults(func=cmd_check)
    p = sub.add_parser("report", help="write a focused upstream range report")
    p.add_argument("old")
    p.add_argument("new")
    p.add_argument("--out")
    p.set_defaults(func=cmd_report)
    for name, func in (("record", cmd_record), ("qualify", cmd_qualify)):
        p = sub.add_parser(name)
        if name == "record":
            p.add_argument("role", choices=ROLES)
        else:
            p.add_argument("--markdown")
        p.add_argument("--gates", nargs="+", required=True)
        p.add_argument("--live-evidence", action="append", default=[])
        p.set_defaults(func=func)
    p = sub.add_parser("cache-key", help="CI cache key for a build target")
    p.add_argument("target")
    p.set_defaults(func=cmd_cache_key)
    args = parser.parse_args()
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
