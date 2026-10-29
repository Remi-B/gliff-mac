# Upstream update: {{old_describe}} → {{new_describe}}

| | |
| --- | --- |
| Current pin | `{{old_sha}}` ({{old_describe}}) |
| Candidate | `{{new_sha}}` ({{new_describe}}) |
| Relation | {{relation}} |
| Commits / files changed | {{commit_count}} / {{files_changed}} |
| Generated | {{date}} by `scripts/upstream.py` |

## Review flags

{{flags}}

## Changes by review area

{{areas}}

## Commits

{{commits}}

## Gates and evidence

Gate results are attached by the update workflow. A required gate that is
**unavailable** (for example live-host evidence from the Linux/Hyprland host)
keeps the candidate **unqualified**; it is never reported as passed.

## Reviewer checklist

- [ ] Rust API changes in `gliff-proto`/`gliff-transport` are absorbed by the
      adapter without exposing upstream wire enums to Swift.
- [ ] Wire changes follow the compatibility rules in `gliff-proto/src/msg.rs`;
      `tests/compatibility/protocol-surface.json` was only rewritten for a
      reviewed, compatible change.
- [ ] Session, input, clipboard and colour changes are covered by fixtures or
      listed as unverified.
- [ ] `scripts/live-host-check.sh` passed against the candidate server, or the
      candidate stays unqualified.
- [ ] Release notes mention user-visible behaviour changes.

Rollback: revert the update commit (gitlink, `upstream-revision`, lockfiles and
records together), then `git submodule update --init --recursive`.
