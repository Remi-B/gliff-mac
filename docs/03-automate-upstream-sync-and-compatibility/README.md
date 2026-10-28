# 03 — automate-upstream-sync-and-compatibility

Status: planned. Dependencies: [02](../02-audit-upstream-protocol-and-portability/README.md).

## Outcome

Make frequent upstream integration an ordinary small update, with automated
checks and a fast rollback. Start now; add native/media/e2e gates as they become
available rather than postponing integration infrastructure until release.

## Work

- [ ] Implement bootstrap and update/check scripts following the
  [update runbook](upstream-update-workflow.md). Require an explicit candidate SHA;
  normal builds never advance the pin. Check clean submodule state and synchronized
  lockfile/provenance records.
- [ ] Add a daily upstream-change check and a manual exact-SHA update workflow.
  Avoid duplicate active update branches/PRs. Generate a focused report for changed
  protocol, transport, session, input, clipboard and colour-reference paths.
- [ ] Run parent Rust formatting/lint/unit/replay checks, native macOS compilation
  for both targets, and the task-02 contract fixtures. Keep upstream Linux checks
  in a separate job using upstream's own workspace/lockfile and required environment.
- [ ] Maintain `tests/compatibility/` records for the initial supported release,
  current pin and candidate. Record client source SHA, server source SHA, both
  dependency lockfiles, protocol/features, architecture, OS, test result and date.
- [ ] Add bridge import checks at task 04, real session/replay checks at 05,
  video/Metal checks at 07–08, input/clipboard checks at 09–11, and full acceptance
  gates at 12. Required checks must distinguish passed, failed and unavailable.
- [ ] Provision or document the Linux/Hyprland host workflow for live tests. Hosted
  macOS CI and mock peers cannot prove compositor or GPU interoperability.
- [ ] Make cache keys include upstream SHA, parent lockfile, Rust/UniFFI versions,
  Xcode version and target. Rebuild after a pin change; do not reuse stale bindings.

## Deliverables and acceptance

- Committed scripts/CI, compatibility manifest and upstream bump report template.
- A clean bootstrap remains on the pinned SHA even when newer upstream commits exist.
- Exercise an update and rollback in a disposable branch/clone. If no newer commit
  exists, validate the candidate workflow using the baseline and test stale pins
  without misreporting that as a real upgrade.
- A deliberate incompatible protocol fixture fails the gate with a useful reason;
  restoring the pin and app lockfile restores passing checks.
- A candidate remains unqualified while required hardware evidence is unavailable.
  Human review is the initial merge policy; automatic merge is a later decision.

Next: [SSH/session implementation](../05-implement-ssh-session/README.md), after task 04.
