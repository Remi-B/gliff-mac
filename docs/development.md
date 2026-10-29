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
checks, logs under `build/portability/`), the Swift package and the Xcode app for both
architectures; on Linux these are reported unavailable. Upstream's own workspace is
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
scripts/build-app.sh
```

This Mac-only command builds the checked-in project/shared scheme without signing,
for `arm64` and `x86_64`, under `build/DerivedData/`. It does not package a release.
The initial app has no connection controls or fake session functionality.

`macos/Packages/GliffCore` is a local Swift package integrated into the Xcode target.
Its current namespace builds without generated artifacts. Task 04 adds generated
Swift/C sources, an XCFramework binary target and the real import/callback smoke
test. The Rust facade already exposes build provenance and uses supported UniFFI
proc-macro scaffolding; no full session API is claimed yet.

Task 04 will automate Apple static-library builds and framework generation. The
`cdylib` output supports bindgen metadata inspection; the app will link the static
library. Do not manually drag generated files into Xcode or commit build products.

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
