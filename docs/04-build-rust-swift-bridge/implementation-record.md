# Task 04 implementation record

Updated: 2026-10-29. Branch `feat/build-rust-swift-bridge`. Status: merged (#5).
Command output, gate summaries and review results are published on the pull request,
not in the repository.

## Delivered

- `gliff-client-core::session`: a transport-independent driver over any
  `AsyncRead`/`AsyncWrite`. It sends `Hello` with exactly the configured decoder support
  and no features, answers `Ping` first, delivers in wire order, acks every accepted
  frame once and in `frame_id` order after its decode report, sends one
  `RequestKeyframe` per lost reference, forwards input, applies the in-flight frame and
  byte budget by not reading, and says `Bye` on cancellation. `Control` is its
  thread-safe, non-blocking handle.
- `gliff-mac-core`: the UniFFI facade (`GliffSession`, `SessionDelegate` exported with
  `with_foreign`, records, enums, typed `GliffError`, `SessionEnd`, `SessionStats`,
  `is_fatal_incompatibility`). One shared two-worker Tokio runtime runs drivers; each
  session has its own delivery thread for callbacks. Sources: recorded streams now; SSH
  targets are validated and reported `Unsupported` until task 05.
- `scripts/build-bridge.sh`: the single build entrypoint (release archives for both Apple
  targets, library-mode Swift generation from each archive with an equality check,
  `lipo`, slice and deployment-target checks, XCFramework, provenance file).
- `macos/Packages/GliffCore`: `GliffCoreFFI` binary target, generated bindings,
  `SessionRelay` (delivery thread for video, main actor for interface events, coalesced
  cursor positions) and a Swift Testing suite. The Xcode app links the package and
  shows the core version, protocol and upstream revision.
- Gates: `bridge-build`, `swift-package` (package and tests built for arm64 and x86_64)
  and `bridge-import` (`swift test`) are required; `build-app.sh` builds the bridge first.
  The portability audit reads deployment targets from the static archive.
- Records: each compatibility record now lists the gates required when it was made, so
  a newly required gate no longer invalidates historical records, while the current-pin
  record must cover every gate required now. `record` evaluates `compatibility-records`
  on the matrix it writes: the summaries necessarily ran it against the stale record.

## Decisions

- **Driver in `gliff-client-core`, threads in `gliff-mac-core`.** The wire logic stays
  portable and testable against a mock server without FFI; the facade only converts
  types and owns the Swift-facing threads. Task 05 adds the SSH stream to the same driver.
- **Back-pressure, not loss.** Frames count against the budget until Swift reports them,
  so the bound also covers frames sitting in the decoder. Reports may arrive out of order;
  acks are still written in order.
- **Generation discard in the bridge.** Frames of a replaced generation still queued for
  delivery are reported discarded before reaching Swift, as rule 2 requires.
- **No dylib.** UniFFI 0.29.4 library mode reads metadata from the static archive, so
  `cdylib` was removed from the crate types (it was only kept for metadata).
- **Replay drains.** A recorded stream waits for in-flight reports at its end so tests can
  check one ack per frame; a live session does not.
- **Swift 6 language mode** compiles the generated bindings unchanged.

## Independent review

GPT Sol reviewed the first commit of the pull request and found five issues, all
confirmed and fixed with a regression test each:

1. Cancellation could not interrupt a write blocked on a peer that stopped reading:
   the whole driver now races cancellation; no `Bye` follows an interrupted write.
2. A `discarded` report of the current generation kept an invalid reference: it now
   loses it like a failure (not for replaced generations or a cancelled session).
3. Predicted frames already queued when a decode failed still reached the decoder: the
   bridge now discards them until the next keyframe. A loss is not raised again by
   frames older than the last delivered keyframe or while one is being recovered, so a
   single keyframe is requested.
4. A record could drop its own requirements (`required: []`): task 03's set is now a
   floor, and the record standing for the pin in use must pass every gate required now.
5. Cursor coalescing could move a position across a cursor shape: a waiting position is
   now delivered before any other event.

## Qualified record

The current-pin record (v0.4.1) is **qualified** again from commit `1dc0159`: this Mac
(macOS 27.0.1, Xcode 27.1), the CI `push` run on macOS 15.7 / Xcode 16.4 and Ubuntu, the
upstream workspace in Arch, and live CPU Single420 and GPU Dual420 runs on `omarchy-mbp`.
It lists the gates required now, including the three bridge gates. The initial-release
record is unchanged and is judged against task 03's gates.

## Acceptance

| Criterion | Evidence |
| --- | --- |
| Single entrypoint from a clean recursive clone, locked dependencies, no dragging | `scripts/build-bridge.sh` from a fresh clone (pull request) |
| Constructor, typed error, asynchronous callback, buffer transfer, cancel/drop cycles | Rust `crates/gliff-mac-core/tests/bridge.rs`, `crates/gliff-client-core/tests/session.rs`; Swift `GliffCoreTests` (SHA-256 of every delivered main/aux buffer against the fixture manifests, 100 cancel/drop cycles) |
| Both slices verified; each Swift consumer builds for its architecture | `lipo` and deployment checks in the script; package, tests and app built for arm64 and x86_64 |
| No callback after teardown, no released Swift object, no UI mutation off-main, bounded memory | Single `onEnded`, delegate released afterwards (Rust strong count, Swift weak reference), relay main-actor assertion, in-flight peak at the configured bound with a slow consumer |
| Bindings regenerated whenever bridge or toolchain changes; task 03 cache and smoke checks | The gates rebuild the bridge on every run; the CI cache key covers Rust, UniFFI, Xcode and lockfiles |

Runtime validation on Intel stays a hardware gate: this Mac has no Rosetta, so the
x86_64 slice is built and linked, not run.
