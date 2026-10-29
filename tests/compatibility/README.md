# Compatibility records

Committed evidence of which upstream server/protocol source the app was checked
against, and how. Maintained by `scripts/upstream.py`; checked by the
`compatibility-records` gate on every `scripts/check.sh`.

| File | Content |
| --- | --- |
| `matrix.json` | Records for the initial supported release, the current pin and the active candidate |
| `protocol-surface.json` | Reviewed wire surface of the pinned `gliff-proto`: version, features, error codes, frame limits and the exact CBOR bytes of one sample of every client and server message |
| `update-report-template.md` | Template of the focused upgrade report written by `scripts/upstream.py update`/`report` |

## Records

Each record in `matrix.json` holds:

- `upstream`: exact source SHA, `git describe`, SHA-256 of upstream's own `Cargo.lock`.
- `client`: the parent commit(s) the gates ran on, whether the tree was dirty, and the
  SHA-256 of the app `Cargo.lock`.
- `protocol`: `PROTOCOL_VERSION`, handshake features and the SHA-256 of the reviewed
  surface record.
- `platforms`: OS, architecture, `rustc`, Xcode and date for each gate summary used.
- `servers`: live-host runs against the unmodified server — host, OS, kernel,
  Hyprland, server version and source SHA, its lockfile SHA-256, arguments, pipeline,
  chroma, configurations and decoded frame counts.
- `gates`: the merged status of every gate, `passed`, `failed` or `unavailable`.
- `result`: `qualified` (every required gate passed), `unqualified` (a required gate is
  unavailable) or `failed` (a required gate failed), with the reason.

The `compatibility-records` gate fails when the current-pin record no longer matches the
checkout: a different pin, upstream lockfile, app lockfile or wire-surface record. After
such an intentional change, re-run the gates and record again (below). A staged
candidate record stands in for the current pin until its gates have been recorded.

Planned gates (bridge import, session, video, Metal, input, displays, clipboard,
acceptance) are listed as unavailable and not required until their task implements them;
that task then marks them required in `scripts/gates.py`. Merge policy stays human review.

## Recording evidence

```bash
scripts/check.sh                                   # build/gates/<os>-<arch>.json
scripts/live-host-check.sh HOST                     # build/live/<sha>-cpu-single420/
scripts/live-host-check.sh HOST --video gpu --chroma dual420
python3 scripts/upstream.py record current-pin \
  --gates build/gates/macos-arm64.json [CI summaries: build/gates/linux-*.json ...] \
  --live-evidence build/live/<sha>-cpu-single420/evidence.json \
  --live-evidence build/live/<sha>-gpu-dual420/evidence.json
```

Gate summaries from the `App checks` workflow are uploaded as `gates-linux`,
`gates-macos` and `gates-upstream-linux` artifacts; `scripts/upstream.py qualify --gates
...` merges them: a failure anywhere fails the gate, a pass on the platform that can run
it passes it, otherwise it stays unavailable. Only a record whose gates all came from a
clean commit should be committed.
