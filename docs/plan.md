# Gliff macOS implementation plan

Status: tasks 01–05 merged; task 06 in review; tasks 07–13 planned.
Updated on 2026-10-30.

Planning location: this specification/plan/task collection is versioned under
`docs/`, alongside the application build/development documentation.

## Goal and source specification

Build a native SwiftUI/AppKit macOS client for an existing Linux/Hyprland
`gliff-server`, retaining upstream wire compatibility and adopting upstream changes
frequently without maintaining a second Linux client or server.

The supplied [technical specification](base-specification.md) is preserved
verbatim. Its hybrid Swift/Rust direction is retained. Its repository layout,
illustrative APIs, build snippets, and incomplete protocol assumptions are adjusted
by this plan and the [architecture decision](01-setup-project-structure/architecture-decision.md).
Use the original for product intent and these documents for implementation work.

## Recommended integration

Make `gliff-mac` an independently maintained application repository. Pin the original
[`omacom/gliff`](https://github.com/omacom/gliff) repository as the read-only
`vendor/gliff` Git submodule. Reuse `gliff-proto` and `gliff-transport` as Cargo path
dependencies; keep the app, portable session adapter, UniFFI bridge, build tooling,
tests, and release lifecycle in the parent repository.

User decision on 2026-10-28: delete the GitHub fork and create a fresh independent
`Remi-B/gliff-mac` repository with the same name. Preserve the original checkout
and history in local backups rather than carrying that ancestry into the app root.
The user recreated the independent public GitHub repository directly. The previous
local folder was removed and replaced by a fresh GitHub clone; task 01's foundation
is reapplied locally on that new history. See task 01's
[implementation record](01-setup-project-structure/implementation-record.md) for the
current state, backup locations and validation evidence.

At the initial inspection, the original fork's HEAD and upstream `main` both resolved to
[`58c742452ded3f10a2ce61f60eb4845f18205e29`](https://github.com/omacom/gliff/commit/58c742452ded3f10a2ce61f60eb4845f18205e29)
(Gliff 0.4.1). That snapshot had no macOS project or `gliff-core` crate. The reusable crates
are separate, but session orchestration in `crates/gliff/src/net.rs` also owns Linux
video decoding, GTK-facing messages, and the Hyprland keymap integration. Importing
that binary wholesale would bring the wrong platform dependencies. Treat this SHA
as the initial baseline, then validate each subsequent pin explicitly.

## Implementation boundaries

- **Upstream:** wire types, framing, transfer engine, reference colour/chroma
  algorithms, and Linux server. No macOS source is added to its Cargo workspace.
- **Application Rust:** a small `gliff-client-core` session adapter using upstream
  protocol/transport crates, plus `gliff-mac-core` as the UniFFI facade. Reuse rather
  than duplicate serialization, clipboard transfers, or the server. Keep any
  session logic adapted from `net.rs` narrow, attributed, and covered by contract
  fixtures. Prefer consuming a future upstream portable session API over keeping
  our adapter indefinitely.
- **Swift/AppKit:** connection UI, app lifecycle, focus and native events,
  pasteboard, VideoToolbox decoding, CoreVideo buffers, and Metal presentation.
  Swift calls a stable app-owned API, not generated upstream wire enums.
- **Build:** separate parent and upstream workspaces and lockfiles, a local Swift
  package for generated bridge artifacts, and a reproducible macOS build script.
  macOS builds select only app crates; Linux server validation is a separate job.

## Corrections and decisions before coding

1. Use the real `crates/gliff-proto` and `crates/gliff-transport` paths. The spec's
   `gliff-core` dependency and replacement workspace member list are illustrative.
2. Use a pinned UniFFI version and supported scaffolding/bindgen APIs. The supplied
   `generate_scenarios` and `setup_scenarios` calls are invalid. Proc-macro mode uses
   `uniffi::setup_scaffolding!()`; see [UniFFI's scaffolding guide](https://mozilla.github.io/uniffi-rs/latest/tutorial/Rust_scaffolding.html).
3. Use the existing SSH stdio protocol: start `gliff-server --stdio` through OpenSSH,
   send `Hello`, handle acknowledgments/configuration and ping/pong, and maintain
   frame acknowledgments. A connection and H.264 callback alone are insufficient.
4. Model encoded video with configuration generation, frame ID, microsecond PTS,
   keyframe flag, main bytes, and auxiliary bytes. Upstream `Dual420` uses two H.264
   streams to reconstruct 4:4:4. Deliver `Single420` first, then dual decode and Metal
   recombination before claiming full-quality Gliff support. Do not advertise
   unsupported codecs or chroma modes.
5. Preserve stream configuration and frame ordering across the FFI. Bound queues
   by count and bytes. Do not discard arbitrary encoded H.264 packets; predictive
   decoding needs reference frames. Prefer dropping completed display frames;
   recover with a keyframe if compressed data must be abandoned.
6. Map macOS physical keys to Linux evdev codes. The server expects XKB keymap text
   or falls back to its US map; it does not accept macOS virtual keycodes or Unicode
   text insertion. A US-only prototype is an explicit intermediate limitation.
   Local layout parity, including French layouts, requires a validated mapping
   strategy; unsupported layouts and IMEs must be disclosed.
7. Scope input capture to the focused remote surface and implement an escape
   shortcut. Avoid a process-wide event monitor that swallows all local events.
8. Start with OpenSSH config/agent/key authentication and normal known-host checks.
   The password/private-key text field in the spec is not an authentication design.
   Resolve GUI authentication and sandbox requirements explicitly; outgoing network
   entitlements alone do not establish SSH file/agent/process access. Plan initial
   direct distribution outside App Sandbox, with signing/hardened runtime assessed
   separately. Do not enable incoming network connections without a requirement.
9. Build Apple targets on macOS with Xcode/Apple SDKs. Build both architectures and
   combine macOS slices correctly before XCFramework packaging; `rustup target add`
   on this Linux planning machine cannot validate the Apple build.

## Ordered tasks

Each task has scope, dependencies, deliverables, and acceptance criteria in its
folder. Tasks 01–05 are **merged**, including local macOS and live-server validation; task 06 is **in review**; tasks 07–13 are **planned**. The order prioritizes repository ownership,
compatibility, and build risks before UI breadth.

| # | Task | Depends on | Completion evidence |
| --- | --- | --- | --- |
| 01 | [setup-project-structure](01-setup-project-structure/README.md) | — | Fresh app history; pinned submodule; local fork backup; bootstrap/checks and universal Xcode build passed in the macOS VM |
| 02 | [audit-upstream-protocol-and-portability](02-audit-upstream-protocol-and-portability/README.md) | 01 | Real contract fixtures; selected crates compile on macOS; platform boundary verified — **merged**: contracts, fixtures, portable boundary and real CPU/GPU captures |
| 03 | [automate-upstream-sync-and-compatibility](03-automate-upstream-sync-and-compatibility/README.md) | 02 | Repeatable upstream bump/revert and compatibility CI; later gates added as implemented — **merged**: tooling, gates, CI, records and live-host checks; bump/rollback rehearsed |
| 04 | [build-rust-swift-bridge](04-build-rust-swift-bridge/README.md) | 02 | Repeatable bindings/XCFramework and Swift import/callback smoke test — **merged**: driver, UniFFI facade, universal bridge, Swift package tests and app link |
| 05 | [implement-ssh-session](05-implement-ssh-session/README.md) | 03, 04 | Authenticated headless SSH and Finder-launch transport probes; bounded video delivery, acknowledgments and clean cancellation — **merged** |
| 06 | [create-native-macos-app](06-create-native-macos-app/README.md) | 04 | Native app shell; typed session UI; deterministic Xcode build — **in review**: view model, live Finder-launched SSH session, app tests gate |
| 07 | [decode-and-display-h264](07-decode-and-display-h264/README.md) | 05, 06 | Real VideoToolbox Single420 decode/presentation, Finder-to-server validation and feedback from native callbacks |
| 08 | [render-full-chroma-metal](08-render-full-chroma-metal/README.md) | 07 | Dual420 pair decoding and reference-verified full-chroma rendering |
| 09 | [implement-remote-input](09-implement-remote-input/README.md) | 07 | Focused pointer/keyboard control; escape; explicit keyboard-layout support |
| 10 | [implement-displays-and-reconnection](10-implement-displays-and-reconnection/README.md) | 08, 09 | Mirror/headless modes, resize, reconnect and session cleanup |
| 11 | [implement-shared-clipboard](11-implement-shared-clipboard/README.md) | 05, 06, 10 | On-demand text/image/file clipboard, cancellation and session isolation |
| 12 | [validate-performance-and-end-to-end](12-validate-performance-and-end-to-end/README.md) | 03, 08, 09, 10, 11 | Cross-platform acceptance, measured latency/memory/quality, and [real SSH multi-hop implementation/validation](12-validate-performance-and-end-to-end/ssh-multi-hop.md) |
| 13 | [package-and-release-macos](13-package-and-release-macos/README.md) | 12 | Tested universal app, signing/notarization workflow and release provenance |

Tasks 04 and 06 can progress alongside compatible work once their prerequisites
exist. Task 03 starts early and gains bridge, video, input, and clipboard checks as
those tasks land. Never mark an unavailable integration gate as passed.

## Milestones and quality gates

- **Foundation (01–04):** clean clone/bootstrap; pinned source and lockfiles;
  macOS Rust checks for Apple Silicon and Intel; generated Swift imports the bridge;
  upstream update and rollback are exercised. Stop feature work if the dependency
  boundary still requires the Linux client stack.
- **View-only alpha (05–07):** Finder-launched app connects through SSH and renders
  a real server's Single420 stream, reports meaningful errors, and disconnects
  without orphaned children/tasks. Clearly label reduced chroma and input absence.
- **Interactive client (08–10):** full-chroma video, keyboard/pointer/scroll/cursor,
  supported layouts, display modes and reconnection. Verify against unmodified
  released and candidate upstream servers.
- **Release candidate (11–13):** clipboard parity, reliability/performance evidence,
  signed distribution and a published server compatibility matrix. Full-chroma and
  promised keyboard-layout support are release gates, not implied future work.

## Frequent upstream integration policy

Normal updates change one Git submodule pin plus the parent lockfile when needed,
adapter adjustments, fixtures, and a compatibility record. They do not merge the
Linux repository into the app's root or regenerate macOS code inside upstream.
Check for updates daily and allow an immediate manual bump to an exact commit;
merge only after available checks pass. Build/replay checks must work without
Hyprland; live validation runs on a separately provisioned Linux host.

Track Rust source compatibility separately from wire compatibility. Sharing
`PROTOCOL_VERSION = 1` is not sufficient: optional features, stream changes,
unknown messages, and actual keyboard/video/clipboard behavior need coverage.
Maintain the initial supported release, current tested pin, and candidate tip as
the compatibility matrix. The detailed [update runbook](03-automate-upstream-sync-and-compatibility/upstream-update-workflow.md)
defines the pin, evidence, patch, and rollback process.

## Completion and open decisions

Release requires both Apple Silicon and Intel evidence, a supported macOS version
chosen from tested API/toolchain requirements, a working Linux/Hyprland host, and
an exercised upstream bump. No macOS build or hardware performance is claimed by
this plan: development is running on Linux. Task 01 used an isolated temporary
Rust installation for portable checks; Apple builds and runtime checks remain pending.

Task 01 proposes macOS 13.0, Rust 1.90.0, UniFFI 0.29.4 and Xcode 16.4 / Swift 6
language mode; task 02 confirmed the Apple dependency boundary with release builds for
both targets (minos 13.0) and found no Linux stack in the app graph.
Task 09 settles keyboard-layout parity and macOS-reserved shortcuts. Task
13 settles signing identity and distribution details. Interactive password/MFA,
Mac App Store sandboxing, IME text protocols, audio, and new video codecs require
separate scoped decisions; they are not prerequisites for the key/agent-based
direct-distribution client described here. Multi-session/tab polish can follow
the single-session release, while state and clipboard ownership remain per-session
from the start.
