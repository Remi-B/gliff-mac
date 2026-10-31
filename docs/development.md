# Development

For a local macOS build guest on this Linux MacBook, see the
[VM setup procedure and current status](macos-vm/README.md).

## Toolchains and platform policy

- Rust **1.90.0**, pinned in `rust-toolchain.toml`, with rustfmt and Clippy.
- UniFFI **0.29.4**, exactly pinned for both runtime and app-owned CLI generator.
- Xcode **16.4** / Swift **6.1** compiler, using Swift 6 language mode and Swift
  package tools 6.0. CI selects that Xcode version explicitly on `macos-15`.
- Proposed deployment target: **macOS 13.0**, Apple Silicon and Intel. Task 02 must
  verify the real protocol/transport dependency graph and later native APIs on Macs;
  a configured target is not a runtime support claim.
- Git, Python 3 and a C toolchain. Full Xcode is needed for Apple builds; selecting
  standalone command-line tools is insufficient for `xcodebuild` app builds.

Xcode 16.4's host OS and deployment requirements are documented by
[Apple](https://developer.apple.com/xcode/system-requirements). Newer Xcode versions
can be evaluated separately; the committed baseline keeps initial builds repeatable.

Bootstrap with `scripts/bootstrap.sh`. It checks for local vendor modifications,
initializes recorded submodules, installs the pinned Rust toolchain/components,
adds both Apple targets on Macs, fetches locked dependencies and validates ownership.
It does not install rustup or Xcode, change your selected Xcode, or advance upstream.

## Checks

```bash
scripts/check.sh            # every gate this host can run
python3 scripts/gates.py --list
```

`scripts/check.sh` runs `scripts/gates.py`, which reports every compatibility gate as
**passed**, **failed** or **unavailable** (with the reason) and writes
`build/gates/<os>-<arch>.json`; it fails when a gate fails. On all platforms: source
pin/workspace structure, the [compatibility records](../tests/compatibility/README.md),
the reviewed protocol wire surface, rustfmt, Clippy, Cargo tests (including the client
contract replay harness over the committed [fixtures](../tests/fixtures/README.md) and a
mock server peer) for the app and the separate `tools/fixture-gen` workspace,
`scripts/generate-fixtures.sh --check` and whitespace. On Macs also both Apple Rust
targets, `scripts/audit-portability.sh` (release builds, dependency tree and archive
checks, logs under `build/portability/`), the bridge build, the Swift package and its
bridge tests, and the Xcode app for both architectures; on Linux these are reported unavailable. Upstream's own workspace is
checked with `--upstream-linux` in its own CI job; live-host evidence comes from
`scripts/live-host-check.sh`. Gates of later tasks are listed as unavailable (planned)
until implemented. CI runs the same entrypoint on Linux and macOS and uploads the
summaries.

`tools/fixture-gen` is its own Cargo workspace with its own lockfile: it links upstream's
CPU encoder (`gliff-sw`, OpenH264 built from source) to encode and verify fixtures, and
must never enter the application graph.

The structure check verifies the gitlink, `upstream-revision`, clean vendor checkout,
source URL, three app workspace members, real vendor dependency paths, and absence
of Linux UI/video/encoder crates in the resolved application graph. Upstream tests are not
mistaken for app workspace members or run implicitly by `cargo test --workspace`.

## Documentation-only CI

App checks always run a lightweight Ubuntu `scope` job: checkout, the 16 scope
regressions, and one read-only Actions API request. The Rust, macOS and upstream
Linux build jobs are skipped when the tested tree differs from a successful
ancestral push of the same workflow only by nonempty changes under `docs/`.
Their check names remain present, so required checks can complete normally.

This also applies to documentation-only commits added to an existing code PR,
provided that its code already passed full CI. The scope compares the actual PR
merge tree, so new base-branch code requires validation. A code/root-file change,
missing baseline/history, API error, unknown event, manual run or reusable
upstream-candidate run executes the full checks. An empty/failed scope result
also defaults to full checks. No workflow-level path filter suppresses the
required App checks.

Run the decision regressions locally with
`python3 -m unittest discover -s tests/ci`. The job summary records the decision
and validated commit. The separate short upstream-automation PR rehearsal keeps
its existing path filters; this optimization targets the expensive App builds.

## Application shell and bridge

```bash
scripts/bootstrap.sh       # once per clone: toolchain, Apple targets, submodule
scripts/build-bridge.sh    # Rust bridge → GliffCore package artifacts
swift test --package-path macos/Packages/GliffCore
scripts/build-app.sh       # runs build-bridge.sh, then the universal Xcode build
scripts/test-app.sh        # the app's hosted tests through the shared scheme
```

`scripts/build-bridge.sh` is the single bridge entrypoint (Mac only, needs full Xcode for
`xcodebuild -create-xcframework`, `lipo` and `otool`). From a clean recursive clone it:

1. builds `gliff-mac-core` in release for `aarch64-apple-darwin` and `x86_64-apple-darwin`
   with `MACOSX_DEPLOYMENT_TARGET=13.0` and `--locked`;
2. builds the app-owned generator `tools/uniffi-bindgen` (UniFFI 0.29.4, the runtime's
   exact version) and generates Swift bindings, the C header and module map from each
   static archive in library mode, with `uniffi.toml` (`GliffCore` / `GliffCoreFFI`); the
   two outputs must be identical;
3. merges both archives with `lipo` into one universal archive, checks its two slices and
   that no object requires a macOS newer than 13.0 (Rust's prebuilt `compiler_builtins`
   objects target 11.0 on arm64);
4. packages it with the header and `module.modulemap` as one
   `macos-arm64_x86_64` library in `GliffCoreFFI.xcframework`.

Outputs, all ignored by Git and rebuilt from scratch on each run:

| Path | Content |
| --- | --- |
| `macos/Packages/GliffCore/Artifacts/GliffCoreFFI.xcframework` | Universal static library, header, module map |
| `macos/Packages/GliffCore/Artifacts/provenance.json` | Source SHA and dirtiness, upstream pin, `rustc`, UniFFI, Xcode, deployment target, slices, SHA-256 of archive, bindings and header |
| `macos/Packages/GliffCore/Sources/GliffCore/Generated/GliffCore.swift` | Generated Swift bindings |
| `build/bridge/` | Per-architecture bindings, headers, universal archive |
| `target/<triple>/release/libgliff_mac_core.a` | Cargo's per-architecture archives (incremental cache) |

Run it before resolving the `GliffCore` package (SwiftPM or Xcode: the package references
a local binary artifact, so resolution fails until it exists) and after any change to the
bridge crates, `uniffi.toml`, `Cargo.lock`, the Rust toolchain or Xcode. For a clean
regeneration delete `build/bridge`, `macos/Packages/GliffCore/Artifacts` and
`Sources/GliffCore/Generated` (the script already does) or `target/` as well. Do not drag
generated files into Xcode or commit them. `gliff-mac-core` builds `rlib` (Rust tests) and
`staticlib` (app linkage) only; library-mode generation reads the static archive, so no
dylib is produced. The Swift package links the archive's native dependency `libiconv`.

The `GliffCore` package has the `GliffCoreFFI` binary target, the `GliffCore` target
(generated bindings plus `SessionRelay`, which splits callbacks between the decoder's
delivery thread and the main actor) and the `GliffCoreTests` Swift Testing suite. The
Xcode app links the package and shows the core's build information. The threading,
ordering, budget and teardown rules are in the [bridge contract](04-build-rust-swift-bridge/bridge-contract.md).

Gates: `bridge-build` (the script), `swift-package` (package and tests built for arm64
and x86_64), `bridge-import` (`swift test` on the host architecture), `macos-app`,
`app-tests`, `video-decode` (the Single420 video suites of the app tests) and
`metal-chroma` (the Dual420 suites: `ChromaRecombinationTests`,
`Dual420DecoderTests`, `FrameJobTests`, `ColorSignallingTests`), plus
`remote-input` (the input suites of the app tests) and `displays-reconnect`
(the driver's liveness tests, the SSH command tests, the orphaned-monitor bridge
tests and the reconnection, resize, request, lifecycle and orphaned-monitor
suites of the app tests).

## Native app

`scripts/build-app.sh` is the documented clean build: it regenerates the bridge,
then runs

```bash
xcodebuild -project macos/GliffMac.xcodeproj -scheme GliffMac -configuration Debug \
  -destination 'generic/platform=macOS' -derivedDataPath build/DerivedData \
  'ARCHS=arm64 x86_64' ONLY_ACTIVE_ARCH=NO CODE_SIGNING_ALLOWED=NO build
```

`scripts/test-app.sh` runs the scheme's test action on the host architecture
(`xcodebuild … -destination "platform=macOS,arch=$(uname -m)" test`); extra
arguments go to `xcodebuild`, for example `-only-testing:GliffMacTests/H264DecoderTests`.
The hosted `GliffMacTests` bundle (Swift Testing, macOS 14+) covers the view
model with a fake session, persistence, the quit drain, the real `LiveSession`
over recorded streams, and the video pipeline: VideoToolbox decode, the
Metal conversion (Single420) and recombination (Dual420) of the committed
fixtures, compared byte for byte with upstream's reference output
(`decoded_bgra_sha256`) and with CPU ports of upstream's chroma and colour
code (`GliffMacTests/ChromaReference.swift`). The project uses file-system synchronized folders: new files
under `macos/GliffMac` or `macos/GliffMacTests` join their target without
project edits (Xcode 16 or later).

Video (`macos/GliffMac/Video`, task [07](07-decode-and-display-h264/implementation-record.md)
and [08](08-render-full-chroma-metal/implementation-record.md) records):
the bridge's delivery thread hands configurations and frames to `H264Decoder`,
which owns one `VTDecompressionSession` per stream (main, and aux for Dual420)
on a serial queue. Each frame is a `FrameJob` its output callbacks complete;
it is reported to the session once, when both halves decoded, when either
failed, or at a 3-second deadline. Decoded pictures (the main and aux buffers
of one frame ID and generation) go to a latest-wins `VideoDisplay`; the remote
surface's `CAMetalLayer` draws them with `VideoRenderer`: an exact BT.709
limited-range conversion pass (Single420) or AVC444 recombination pass
(Dual420), then an aspect-fit presentation pass. Shaders compile from
source at run time, so no separate Metal toolchain is needed. The `video` log
category records decoder sessions, failures and, at each session's end, its
frame counters, Dual420 pair counters and native costs (no host or picture
content).

Replaying recorded live sessions natively (for example the
`session.gliffstream` that `scripts/live-host-check.sh` writes):

```bash
TEST_RUNNER_GLIFF_LIVE_STREAMS=/abs/a.gliffstream:/abs/b.gliffstream scripts/test-app.sh \
  -only-testing:GliffMacTests/Dual420DecoderTests/recordedLiveStreamsDecodeNatively
```

Every frame must decode; the Metal output must equal the CPU reference, and a
`<name>.json` manifest beside a stream (`gliff-fixture-gen describe`) must match.
The test prints one `live-replay` line per stream; it is skipped without the
variable.

Remote input (`macos/GliffMac/Input`, [task 09 record](09-implement-remote-input/implementation-record.md)):
while a window captures input, a local key monitor and the surface's mouse
overrides feed that session's `InputForwarder`, which sends physical keys as
evdev codes, pointer positions through the renderer's fit and `scale_milli`,
evdev buttons and Wayland-style scroll axes, and releases everything still down
when capture ends. The remote keymap follows the macOS input source (U.S., ABC,
French and French – PC; others fall back to U.S., shown in the status bar) and a
switch is sent before the next key. The remote cursor shape replaces the local
pointer while capturing. ⇧⎋ releases capture; reserved macOS shortcuts stay
local. No Accessibility or Input Monitoring permission is used. The
`remote-input` gate runs the input suites of the app tests.

Displays and reconnection ([task 10 record](10-implement-displays-and-reconnection/implementation-record.md)):
a virtual display (`--headless`) or a mirrored output (`--output NAME`, empty for
the focused one) is chosen in the form and kept with the recent host. The remote
surface reports its size in backing pixels and scale; once it holds for 200 ms the
controller sends `Resize`, which resizes a virtual display at that scale or scales a
mirrored stream to fit. A session that loses its link after streaming is replaced
automatically after 1, 2, 4, 8 and 16 seconds (a new SSH process, handshake,
decoder and input state each time); setup refusals (`GliffError.Setup`: host key,
key authentication, missing server), incompatible servers, first attempts and the
user's disconnect are not retried. Sleep ends the session and wake starts a new
one; a network path coming back cuts the wait short. Once streaming, the driver
pings a server silent for 5 seconds and fails the session after 15 seconds of
silence. `scripts/live-displays-check.sh HOST USER IDENTITY` runs the live resize,
mirror, kill, stall, network-drop and connect/cancel checks with
`examples/display_probe` and checks the host and the Mac for leftovers.

Orphaned virtual monitors ([task 14 record](14-clean-up-orphan-monitors/implementation-record.md)):
after every connection, a separate SSH command with the session's policy runs a
fixed script that lists `gliff-<pid>` outputs whose server no longer runs. A sheet
offers to remove them (Ignore is remembered per window); Settings › Virtual
monitors removes them without asking. A host without Hyprland is skipped.
`scripts/live-monitors-check.sh HOST USER IDENTITY` checks it live with a running
session, a killed one and a stray output, and checks for leftovers;
`examples/monitor_probe` runs a single check or removal.

`SessionController` (one per window, main actor) owns the connection form and
phases, and ignores callbacks from sessions it replaced. `SessionRegistry` owns
every started session until the bridge reports its end, so closing a window or
quitting never orphans SSH. Views use only controller types, never bridge or
upstream records. See the [task 06 record](06-create-native-macos-app/implementation-record.md).

A Finder-launched app is the responsible process for its `/usr/bin/ssh` child.
macOS Local Network privacy therefore applies to it: allow Gliff once in
System Settings › Privacy & Security › Local Network to reach `.local` and other
LAN hosts. A missing grant shows up as an immediate "could not reach the host".
Launching the binary from Terminal hides this, because Terminal is the
responsible process. Debug builds are ad-hoc signed, so every rebuild is a new
identity to this check and needs the grant again before a live run.

For live checks, debug builds read a one-shot `GliffDebugAutoConnect` default (a
JSON `ConnectionRequest`), remove it and connect, so a Finder launch needs no UI
scripting:

```bash
defaults write com.remi-b.gliff-mac GliffDebugAutoConnect -string \
  '{"host":"HOST","user":"","port":"","identityFile":"/Users/me/.ssh/id_ed25519","serverPath":"/abs/gliff-server","headless":true}'
osascript -e 'tell application "Finder" to open POSIX file "'"$PWD"'/build/DerivedData/Build/Products/Debug/GliffMac.app"'
log stream --predicate 'subsystem == "com.remi-b.gliff-mac"' --info
```

The log records phases and quit draining, never hosts, users or paths. Release
builds do not contain the hook.
Intel runtime is not covered on Apple silicon without Rosetta; it is a hardware gate.

## Workspaces and dependency updates

The root workspace owns only the two app crates and generator. `vendor/gliff` is
excluded and remains a separate workspace. Upstream library manifests inherit from
their own root; app path dependencies reuse those crates without changing them.

The parent committed `Cargo.lock` controls app dependency resolution. Upstream's
lockfile controls a separate server build on Linux and does not pin app transitive
dependencies. Normal build/check commands use `--locked`; when changing dependencies,
refresh the app lockfile intentionally and review its diff. The Cargo resolver
prefers versions compatible with the declared Rust minimum.

For a reviewed upstream update, run `python3 scripts/upstream.py update <full-sha>`: it
checks the clean pin, fetches upstream, refuses untrusted, stale or abbreviated
candidates, checks the commit out detached in `vendor/gliff`, updates `upstream-revision`,
stages the gitlink, refreshes the parent lockfiles only as Cargo requires, adds an
unqualified candidate record and writes a focused range report. Then run the checks and
live test and record the evidence. The [update runbook](03-automate-upstream-sync-and-compatibility/upstream-update-workflow.md)
covers review, records and rollback; the `Upstream candidate` workflow does the same
daily and on demand. Normal bootstrap uses `git submodule update --init --recursive
--checkout` and never `--remote`.

Do not patch vendor files in build scripts. Record any temporary upstream fork/
patch branch and its removal condition explicitly. Native/media gates arrive with their
corresponding features (see `scripts/gates.py --list`).

## Artifacts and permissions

Commit source, project/schemes, manifests, the parent lockfile and source pin.
Ignore `target/`, `build/`, SwiftPM/Xcode caches and generated bridge artifacts.
Fixtures will include exact source/settings/checksums without private desktop data.

Initial distribution is outside App Sandbox. The project enables hardened runtime
as a baseline but adds no entitlements (no incoming network, capture or Apple
events) or signing secrets. The Info.plist declares `NSLocalNetworkUsageDescription`
for LAN servers. Task 06 validated subprocess, SSH config/agent and filesystem
behaviour in a Finder-launched app; signing and notarization are task 13.

## GUI SSH transport and headless probe

`ConnectionTarget.ssh` takes host/config alias, optional user/port/server path,
optional absolute identity file, a headless Boolean and a `VideoMode` enum
(`auto` omits `--video`; `cpu`/`gpu` pass the two values the pinned server accepts). It invokes `/usr/bin/ssh`
with local argv, strict known-host verification, batch key/agent authentication,
no TTY and no forwarding/control socket. Existing SSH config aliases, identities,
agent and ProxyJump still apply. The remote executable is shell quoted and options
are structured; there is no public raw command or SSH flags interface. Establish
and verify the host fingerprint and key authentication in Terminal before GUI use.
Missing GUI agents require an explicit identity or a configured accessible agent.
Never weaken known-host verification to resolve errors.

A transport-only live probe uses the public bridge API and always requests headless:

```bash
cargo run --locked -p gliff-mac-core --example ssh_probe -- omarchy-mbp.local remi /Users/remi/.ssh/id_ed25519_omarchy /home/remi/.cache/gliff-mac-live/gliff-server-58c742452ded3f10a2ce61f60eb4845f18205e29.bin
```

It prints no pixel/encoded data, reports frame completion synthetically (not a
VideoToolbox decode claim), waits at most 30 seconds, cancels and waits for cleanup.
Use `env -u PATH` with the built absolute probe path for a GUI-like PATH preflight;
this does not prove a LaunchServices/Finder launch. Final acceptance must exercise
the app through Finder with its real SSH_AUTH_SOCK and confirm no remaining SSH
processes after repeated stop/quit. No live evidence is claimed by the process gate.

The probe runs for ten seconds by default; set `GLIFF_PROBE_SECONDS=30` on a
slow network (range 1–60). `GLIFF_PROBE_REPORT=/absolute/path/report.json` writes
metadata and frame/ack/pong counters after success. It verifies a pong and an ack
for each delivered frame, using synthetic decode completion; this is transport
evidence, not VideoToolbox decoder validation. For GUI environment validation,
launch a temporary app wrapper through **Finder**. A shell `open` invocation can
pass the caller's environment, so it does not by itself prove Finder's PATH or
agent behavior. Never capture the physical display during these checks.

SSH policy is enforced through a private session-scoped config included by every
OpenSSH-generated ProxyJump hop. It includes the ordinary user and system config
after mandatory verification, batch-authentication and forwarding settings. No
user SSH files are modified. Agent authentication is supported; forwarding the
agent or X11 connection to the server is disabled. Proxy helpers belong to the
session's process group and are terminated during cancellation. Custom helpers
that deliberately daemonize into a separate session remain trusted user config.

### Keyboard layout validation

Task 09 derives supported printable XKB symbols from Apple's Unicode layout data,
including dead accents; stock xkeyboard-config Mac variants differ from macOS.
Right Option supplies symbols (AltGr); left Option remains Alt for shortcuts.
Export all four supported sources for ANSI/ISO translation data with
`scripts/export-keyboard-layouts.sh`, then run
`python3 scripts/check-keyboard-layouts.py build/input-layouts/layouts.json --ssh USER@HOST --identity PATH`
against Linux with libxkbcommon. This read-only check compiles each production map,
compares printable levels and tests dead-key composition without accessing the
compositor, GPU, input or server. It does not replace physical keyboard/live UI
acceptance. The [task record](09-implement-remote-input/implementation-record.md)
lists current behavior, reserved shortcuts and remaining checks.
