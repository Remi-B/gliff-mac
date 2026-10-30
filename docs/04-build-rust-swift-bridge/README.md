# 04 — build-rust-swift-bridge

Status: merged — bridge, build entrypoint, Swift package, app link and gates implemented. Dependencies: [02](../02-audit-upstream-protocol-and-portability/README.md).

Results: [bridge contract](bridge-contract.md), [implementation record](implementation-record.md).

## Outcome

A stable app-owned Rust/Swift boundary and a repeatable native build/import path,
independent of Linux UI and video libraries.

## Work

- [x] Define `gliff-client-core` contracts from task 02 and expose them through
  `gliff-mac-core`: connection options, session handles, typed errors/status,
  stream configuration, encoded main/aux frame envelopes, cursor/input commands,
  decode feedback and future clipboard hooks. Avoid premature wire API duplication.
- [x] Specify thread/actor ownership, ordered config/frame delivery, callback lifetime,
  bounded queues/byte budgets, cancellation and generation IDs. SwiftUI state changes
  run on the main actor; decode/render callbacks never block the network reader.
- [x] Pin one UniFFI runtime/generator version and use supported proc macros,
  including `uniffi::setup_scaffolding!()` and explicitly exported callback traits.
  The source spec's `*_scenarios` calls are placeholders, not usable APIs.
- [x] Provide an app-owned bindgen binary, following the
  [official generator setup](https://mozilla.github.io/uniffi-rs/latest/tutorial/foreign_language_bindings.html).
  Include `rlib` for Rust tests and `staticlib` for app linkage; use a dylib only
  if needed for metadata generation, not as an unexplained runtime dependency.
- [x] On a Mac, build release archives for both Apple targets with one deployment
  target, generate Swift/C headers/module map deterministically, merge the two
  macOS architecture archives with `lipo`, then package the macOS library as an
  XCFramework using `xcodebuild`. Do not package two conflicting macOS slices.
- [x] Wire a local `GliffCore` Swift package into the checked-in Xcode app. Its
  generated Swift and C module names/search paths must agree. Bootstrap generation
  must happen before resolving a package that references a local binary artifact.
- [x] Document native Mac/Xcode prerequisites, artifact/cache locations, generator
  provenance and clean regeneration; keep generated binaries out of source control.

## Deliverables and acceptance

- A single documented build entrypoint produces the bridge package/XCFramework
  from a clean recursive clone with locked dependencies, without manual dragging.
- Rust tests and a minimal Swift consumer exercise a constructor, typed error,
  asynchronous callback, buffer transfer and repeated cancel/drop cycles.
- Both architecture slices are verified and each Swift consumer builds for the
  intended architecture. Runtime validation on Intel remains a hardware gate.
- No callbacks access released Swift objects, mutate UI off-main, or survive
  completed teardown; a slow callback cannot grow memory without a bound.
- Generated bindings are regenerated whenever the bridge/toolchain changes;
  task 03's cache and smoke checks include this build.
