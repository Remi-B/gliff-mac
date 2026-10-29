#!/usr/bin/env python3
"""Decide whether the App checks must run in full for the checked-out commit.

Checks are skipped only when the tree differs from an already validated
commit by files under docs/ alone. Validated means: a successful push run of
this same workflow, on a commit that is an ancestor of the tested commit.
Anything uncertain (API error, missing history, odd event) means full checks.
"""
import json
import os
import subprocess
import sys
import urllib.request

DOCS_PREFIX = "docs/"
SKIPPABLE_EVENTS = {"push", "pull_request"}
WORKFLOW_FILE = "ci.yml"


def git(repo, *args):
    return subprocess.run(
        ["git", "-C", repo, *args], capture_output=True, check=False
    )


def is_full_sha(value):
    return (
        isinstance(value, str)
        and len(value) == 40
        and all(c in "0123456789abcdef" for c in value)
    )


def is_ancestor(repo, candidate, head):
    return git(repo, "merge-base", "--is-ancestor", candidate, head).returncode == 0


def docs_only_diff(repo, candidate, head):
    """True when candidate..head changes at least one path, all under docs/."""
    out = git(repo, "diff", "--name-only", "--no-renames", "-z", candidate, head)
    if out.returncode != 0:
        return False
    paths = [p for p in out.stdout.split(b"\0") if p]
    return bool(paths) and all(p.startswith(DOCS_PREFIX.encode()) for p in paths)


def decide(repo, event, input_ref, head, runs):
    """Return (full, reason). `runs` is the parsed workflow_runs list or None."""
    if input_ref:
        return True, "manual or reusable run with an explicit ref"
    if event not in SKIPPABLE_EVENTS:
        return True, f"event {event or 'unknown'} always runs full checks"
    if not is_full_sha(head):
        return True, "tested commit could not be determined"
    if not isinstance(runs, list):
        return True, "no validated baseline could be read"
    for run in runs:
        if not isinstance(run, dict):
            continue
        sha = run.get("head_sha")
        if (
            run.get("conclusion") != "success"
            or run.get("event") != "push"
            or not is_full_sha(sha)
            or not is_ancestor(repo, sha, head)
        ):
            continue
        if docs_only_diff(repo, sha, head):
            return False, f"only docs/ changed since validated commit {sha[:12]}"
    return True, "no validated ancestor differs from this commit by docs/ only"


def fetch_runs(repository, token):
    url = (
        f"https://api.github.com/repos/{repository}/actions/workflows/"
        f"{WORKFLOW_FILE}/runs?status=success&event=push&per_page=100"
    )
    request = urllib.request.Request(
        url,
        headers={
            "Accept": "application/vnd.github+json",
            "Authorization": f"Bearer {token}",
            "X-GitHub-Api-Version": "2022-11-28",
        },
    )
    with urllib.request.urlopen(request, timeout=20) as response:
        data = json.load(response)
    runs = data.get("workflow_runs")
    return runs if isinstance(runs, list) else None


def main():
    env = os.environ
    event = env.get("GITHUB_EVENT_NAME", "")
    input_ref = env.get("INPUT_REF", "").strip()
    repo = env.get("CI_SCOPE_REPO", ".")
    full, reason = True, "scope check failed; running full checks"
    try:
        head = git(repo, "rev-parse", "HEAD").stdout.decode().strip()
        runs = None
        if not input_ref and event in SKIPPABLE_EVENTS:
            try:
                runs = fetch_runs(env["GITHUB_REPOSITORY"], env["GITHUB_TOKEN"])
            except Exception:  # never print tokens or raw HTTP errors
                runs = None
        full, reason = decide(repo, event, input_ref, head, runs)
    except Exception:
        pass
    print(f"full={str(full).lower()}: {reason}")
    if env.get("GITHUB_OUTPUT"):
        with open(env["GITHUB_OUTPUT"], "a") as handle:
            handle.write(f"full={str(full).lower()}\n")
    if env.get("GITHUB_STEP_SUMMARY"):
        verdict = "Full checks" if full else "Expensive checks skipped (docs-only)"
        with open(env["GITHUB_STEP_SUMMARY"], "a") as handle:
            handle.write(f"### CI scope\n\n**{verdict}**: {reason}\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
