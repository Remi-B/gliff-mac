# Task 01 implementation record

Updated: 2026-10-28. Status: replacement GitHub repository cloned and local
foundation reapplied; initial macOS build validation complete.

## Repository state

- Independent app checkout: `~/Projects/Gliff/gliff-mac`.
- GitHub repository: `https://github.com/Remi-B/gliff-mac`, verified public and
  independent (`isFork == false`). The user deleted/recreated it directly.
- Fresh clone created with `gh repo clone Remi-B/gliff-mac` after deleting the
  previous local app folder. `origin` points at the new repository.
- Default branch: `master`. Its initial remote commit is
  `22d8c1aa840a72d79229182f6522cb5c5e1818de` (`Initial commit`), containing only LICENSE.
  That license is preserved unchanged. Application setup is reviewed on
  `feat/setup-project` against this baseline.
- The task 01 scaffold is reapplied on the new remote history. App CI now checks
  pushes on all branches rather than assuming `main`.
- Local scaffold commit: `b1b6fa7dbd9a35080d85c4548f69cbe34cc5a243`
  (`Set up independent macOS project foundation`), directly following the new
  repository's initialized LICENSE commit. Documentation is versioned in a
  subsequent commit; VM tooling and macOS validation follow on `feat/setup-project`.
- Original clean fork checkout: `~/Projects/Gliff/.backups/gliff-mac-fork-20261028`.
  Its baseline tag is `archive/fork-before-recreation-20261028`.
- Verified all-refs source backup:
  `~/Projects/Gliff/.backups/gliff-mac-fork-20261028.bundle`.
- Verified prepared-foundation backup:
  `~/Projects/Gliff/.backups/gliff-mac-foundation-20261028.bundle`. It preserves the
  earlier local root commit `d79af05dcf4e8aba0152f652572dccb07800577b`; that commit
  does not become an ancestor in the replacement repository.
- Canonical specification/plan/task documents are now versioned inside the app
  repository under `docs/`, following the user's request to move them back.

The user explicitly requested deleting/recreating the GitHub repository under the
same name with fresh app history, superseding the initial history-preserving
migration proposal. Existing public visibility is to be preserved.

## GitHub replacement resolved

The earlier `gh repo delete` attempt lacked the `delete_repo` scope. The user
subsequently deleted/recreated the repository on GitHub and explicitly requested
removing the local app folder and cloning the replacement. That operation is now
complete. No further deletion or token refresh is needed.

Before deletion, the prepared foundation was saved in a verified bundle and source
archive. The new GitHub clone started from its actual initialized history, then
received the scaffold as app source without importing old root ancestry. GitHub
keeps its initial LICENSE commit as the `master` baseline; application changes are
proposed on `feat/setup-project`.

## Implemented foundation

- Independent Cargo workspace with exactly `gliff-client-core`, `gliff-mac-core`
  and app-owned `gliff-uniffi-bindgen`; parent `Cargo.lock` committed.
- Unmodified `omacom/gliff` submodule at
  `58c742452ded3f10a2ce61f60eb4845f18205e29`, with a checked source-provenance record.
  Protocol/transport path dependencies inherit from upstream's separate workspace.
- Minimal UniFFI build-provenance facade and matching pinned generator. No session,
  media pipeline or generated Swift bridge is represented as implemented.
- Checked-in Xcode app project/shared scheme, native launch shell, local `GliffCore`
  Swift package, and native-test/contract-fixture ownership locations.
- Rust 1.90.0, UniFFI 0.29.4, Xcode 16.4 / Swift 6 language mode; proposed macOS 13.0
  deployment target and Apple Silicon/Intel builds.
- Bootstrap, workspace/source-integrity checks, portable Rust checks, Mac app build
  entrypoint and separate Linux/macOS app CI jobs. No inherited Linux release jobs.
- App README/development/ownership docs, MIT license and preserved upstream notice.
  Generated artifacts/caches are ignored; source planning is versioned in
  `docs/`.

## Validation performed

On Linux with Rust installed only under `/tmp/gliff-mac-toolchain/` (the user's
normal toolchain/PATH configuration was not changed):

- `scripts/bootstrap.sh` and the full portable `scripts/check.sh` pass.
- Cargo metadata resolves exactly three app workspace members and the intended
  vendor crates. No GTK, Wayland, Hyprland, VA-API or Vulkan/DRM stack is resolved.
- rustfmt and Clippy with warnings denied pass; Cargo unit/doc test harnesses pass.
  The scaffold currently has zero behavioral tests; later tasks introduce them.
- Ordinary local clone + bootstrap and recursive local clone both retain the same
  clean upstream SHA. A deliberately dirty vendor checkout is rejected correctly.
- Shell/Python syntax, app documentation links and shared scheme XML validate.
- The Xcode project was generated and reparsed with Xcodeproj 1.27.0 in a temporary
  Ruby environment; local Swift package/product and source references resolve.
- Original fork and prepared-foundation bundles both verify. The fresh GitHub clone
  preserves its LICENSE and initializes the exact upstream SHA through bootstrap.
- The full portable bootstrap/check sequence passes again in the replacement
  checkout. At that validation stage, remote HEAD remained the initial LICENSE
  commit and the application commits had not yet been pushed.

In the installed Intel macOS 15.8.2 VM, using full Xcode 16.4 (16F6), Swift 6.1.2,
the macOS 15.5 SDK and Rust 1.90.0:

- `scripts/vm/build.sh` synchronizes local history/source to native APFS and runs
  the complete bootstrap/check entrypoints successfully.
- Structure checks, rustfmt, Clippy with warnings denied, and Cargo unit/doc test
  harnesses pass. There are still zero behavioral tests in this scaffold.
- Cargo checks for both `aarch64-apple-darwin` and `x86_64-apple-darwin` pass.
- The `GliffCore` Swift package and the universal Debug app build pass;
  `xcodebuild` reports `BUILD SUCCEEDED`.
- `lipo -info` confirms x86_64 and arm64 app slices. `vtool -show-build` reports
  deployment target 13.0 and SDK 15.5 for both. The app launches and remains
  running in the Intel guest.
- Cocoa now resolves through `SDKROOT`, replacing the generated project reference
  to a fixed macOS 15.0 SDK path.
- The genuine VM desktop/Terminal screenshot and CLI/build evidence are retained
  outside Git under `~/.local/share/gliff-mac-vm/evidence/` and `logs/`.
  See the [VM guide](../macos-vm/README.md) for setup and replay commands.

Task 01's initial Mac build gate is complete. Hosted CI, runtime on Apple Silicon,
and hardware Metal/VideoToolbox validation have not run. This validates the project
foundation, not a functioning remote desktop client or generated Rust/Swift bridge.
Task 02 expands the portability/protocol audit.
