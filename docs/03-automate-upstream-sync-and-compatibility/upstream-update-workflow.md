# Upstream update and rollback runbook

Status: implemented by task 03. Commands: `scripts/upstream.py` (status, update,
abort, report, check, record, qualify, cache-key), `scripts/check.sh` /
`scripts/gates.py` (gates), `scripts/live-host-check.sh` (live host) and the
`Upstream candidate` workflow. Records: [`tests/compatibility/`](../../tests/compatibility/README.md).

## Quick reference

```bash
python3 scripts/upstream.py status                 # pin vs upstream main, no change
python3 scripts/upstream.py update <full-sha>      # stage gitlink + revision + locks + candidate
scripts/check.sh                                   # every gate this host can run
scripts/live-host-check.sh <linux-host>            # live server evidence (CPU Single420)
scripts/live-host-check.sh <linux-host> --video gpu --chroma dual420
python3 scripts/upstream.py record current-pin --gates build/gates/*.json \
  --live-evidence build/live/<run>/evidence.json   # after committing the update
python3 scripts/upstream.py abort                  # drop a staged, uncommitted candidate
git revert <update-commit> && git submodule update --init --recursive   # rollback
```

`update` refuses an abbreviated SHA, a branch or tag name, a dirty parent or vendor
checkout, a commit that is not on upstream `main` or a release tag, and a candidate that
is older than or diverged from the pin (`--allow-stale` exists only to rehearse such a
pin in a disposable branch; its record says `stale`/`diverged`). A candidate equal to the
pin is a rehearsal: it writes the report and stages nothing.

## Normal checkout and source ownership

Developers either clone recursively or run `git submodule update --init --recursive`
after cloning/switching parent revisions. CI explicitly checks out submodules.
The parent gitlink is authoritative; `.gitmodules` supplies the URL, not permission
to track upstream `main` automatically. A missing or dirty submodule is an error.

App builds use the parent committed `Cargo.lock` and `--locked`. A Linux server
build uses `vendor/gliff/Cargo.lock` in its separate workspace. Do not assume the
two resolve identical third-party versions. Build metadata records both lockfiles
and the exact upstream commit. Never edit generated artifacts or vendor manifests
to make a build pass without recording the source change.

## Candidate update

1. Start from a clean parent checkout with a clean pinned submodule. Fetch upstream
   refs, choose an explicit full candidate SHA from the trusted upstream repository,
   and record the old/new commits and release tags when available.
2. Review the range, especially `Cargo.toml`, relevant crate manifests, protocol
   fields/features, payload validation, SSH spawning, client session behavior,
   frame acknowledgments, colour/chroma references, input and clipboard behavior.
   Rust API changes and wire changes are separate review items.
3. On a dedicated parent update branch, check out the candidate commit detached
   inside `vendor/gliff`. Update nested submodules if upstream adds any. The parent
   change records the gitlink, not copies of vendor files.
4. Resolve app dependency changes intentionally and commit the parent lockfile if
   needed. Preserve unrelated locked versions where possible. Adjust the small
   app adapter or its capabilities; do not publish upstream wire enums as a new
   Swift API accidentally. Regenerate the bridge using its matching pinned tool.
5. Run deterministic contract/replay tests, Rust checks, Apple target builds and
   Swift bridge/app checks. Add media/Metal/native tests as implemented. Verify
   both protocol-version mismatch directions and unknown optional features.
6. Test the new client against the minimum supported server release and candidate
   server, plus current pin if distinct. Test mirror/headless, CPU/GPU server paths,
   both chroma modes, resize, input, reconnection and clipboard to the extent these
   features are implemented. Live server tests require the Linux host; fixtures
   alone must not be labeled end-to-end validation.
7. Update `tests/compatibility/` with exact versions, test evidence and unsupported
   cases. Publish the focused update report for review. Merge only when implemented
   required gates pass and any changed behavior is reflected in release notes.

Steps 1, 3, 4 (lockfile synchronisation) and the candidate record are what
`scripts/upstream.py update` automates; it writes the step-2 range report to
`build/upstream/`. A changed wire surface fails the `protocol-surface` gate with the
affected messages; rewrite `tests/compatibility/protocol-surface.json`
(`GLIFF_WRITE_PROTOCOL_SURFACE=1 cargo test -p gliff-client-core --test protocol_surface`)
only after reviewing that the change is compatible.

## Live host

`scripts/live-host-check.sh HOST [--sha SHA]` sends the exact upstream commit to the
host as a Git bundle, builds the unmodified `gliff-server` there with upstream's own
lockfile (installing a private Rust 1.90.0 under `~/.cache/gliff-mac-live` if the host
has no Cargo), then records a real `--stdio --headless` session from the Mac with the
contract recorder: `Hello`, `Pong`, a `FrameAck` per decoded frame, a client `Resize`
after the first frame and `Bye`. It replays the bytes through the app's client
contract and upstream's reference decoder, and writes `evidence.json`, the stream,
its manifest and decoded PNGs under `build/live/`. It needs key/agent SSH access to a
user with an active Hyprland session; nothing is installed system-wide and the
headless output never shows a physical monitor. Hosted CI cannot run it, so the
`live-host` gate is unavailable there and a candidate stays unqualified until a
maintainer adds the evidence.

Daily checks discover candidates; manual invocation can start immediately after
an upstream fix. Keep one active candidate update per base branch. Do not schedule
an always-moving dependency in the production build.

## Expected update contents

- Gitlink old/new full SHA and meaningful upstream change summary.
- Parent lockfile and toolchain changes only when needed.
- Small adapter/capability/fixture adjustments and updated provenance.
- Compatibility evidence, including explicitly unavailable hardware cases.
- Any temporary downstream patch record and its removal condition.

If one bump routinely needs broad copied code edits, revisit the portable session
boundary and propose a reusable upstream API. Submodules prevent source merge
conflicts; they cannot prevent upstream Rust APIs or behavior from changing.

## Rollback

Revert the parent update commit(s), including the gitlink, parent lockfile and
adapter/fixture changes as a compatible set. Run
`git submodule update --init --recursive` to restore the selected source and rebuild
generated Swift/framework artifacts. Re-run the previous compatibility smoke tests.
Roll back by parent commit rather than moving the submodule alone, and never
force-push released history. Release provenance retains the failed candidate for
investigation while the previous passing app/server pairing remains available.

The repository-layout migration is a separate, larger rollback covered by task 01;
exercise that in a disposable clone rather than using the routine pin-bump path.
