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

## Application shell and bridge

```bash
scripts/bootstrap.sh       # once per clone: toolchain, Apple targets, submodule
scripts/build-bridge.sh    # Rust bridge → GliffCore package artifacts
swift test --package-path macos/Packages/GliffCore
scripts/build-app.sh       # runs build-bridge.sh, then the universal Xcode build
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
and x86_64), `bridge-import` (`swift test` on the host architecture) and `macos-app`.
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
as a baseline but adds no incoming-network/capture entitlements or signing secrets.
System SSH config, agent and Finder launch behavior need validation in later session
and release tasks; an entitlement alone does not establish access.
