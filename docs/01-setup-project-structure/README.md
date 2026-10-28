# 01 — setup-project-structure

Status: complete, including local macOS build validation. Dependencies: none. See the
[implementation record](implementation-record.md) for evidence and remaining runtime/CI limits.

## Outcome

Define and establish how the macOS app integrates with Gliff. Follow the
[architecture decision](architecture-decision.md): independently owned app source,
an unmodified pinned upstream submodule, and two separate Cargo workspaces. Per the
user's updated direction, recreate the GitHub repository with fresh application
history; preserve the original fork as local backups. Version the planning docs
inside the app repository under `docs/`.

## Work

- [x] Inventory the original clean checkout; preserve its full checkout, all-refs
  Git bundle and named `archive/fork-before-recreation-20261028` baseline tag.
- [x] Replace the fork with a fresh public `Remi-B/gliff-mac` repository and clone
  it at the original checkout path. The user recreated it directly; the old local
  app folder was deleted and the new repository cloned with `gh`. Reapply the
  foundation locally on the fresh history, preserving its initialized license.
- [x] Add `vendor/gliff` from `https://github.com/omacom/gliff.git`, initially at the
  verified full SHA `58c742452ded3f10a2ce61f60eb4845f18205e29`. Preserve its MIT license.
- [x] Establish the independent root workspace with app-owned `gliff-client-core` and
  `gliff-mac-core` manifests; keep the bindgen tool app-owned. Explicitly exclude the
  nested upstream workspace; verify Cargo workspace inheritance rather than copying
  or modifying upstream manifests. The next task proves dependency portability.
- [x] Establish app `macos/`, `scripts/`, `tests/fixtures/`, and development docs ownership;
  version the canonical spec/plan/task folders in the app's `docs/` directory.
  Check in an Xcode project and shared scheme; use a local Swift package for the
  bridge. Ignore reproducible generated bindings/frameworks and build caches.
- [x] Pin the Rust toolchain and document the Xcode/Swift version and proposed
  minimum macOS target. Select a target supported by both architectures and chosen
  APIs; task 02 must verify it. Keep macOS application versioning independent of Gliff.
- [x] Add bootstrap/check entrypoints that initialize submodules at the recorded
  commit, diagnose missing tools, and check unexpected source changes. Replace
  inherited Linux-only CI with a minimal app check; expand it in tasks 02–03.
- [x] Write root app development instructions, attribution, workspace/lockfile
  ownership, generated artifact policy, and the migration rollback procedure.
- [x] Execute the Apple build checks in the installed macOS VM with Xcode 16.4:
  Rust native/cross-target checks, Swift package and universal app build pass.
  The generated app launches in the Intel guest. Hosted CI and Apple Silicon
  runtime validation have not been executed; those are separate checks.

## Deliverables and acceptance

- A reviewable initial application commit, retained fork backup/ref, `.gitmodules`, explicit
  app workspace, and root app documentation. Planning files survive unchanged.
- A clean recursive clone and a normal clone followed by bootstrap produce the
  same upstream SHA; bootstrap never follows a moving branch implicitly.
- `git submodule status` and `git -C vendor/gliff status --porcelain` confirm the
  recorded clean upstream checkout. Parent `cargo metadata` identifies only intended
  app workspace members; upstream remains independently buildable on Linux.
- No duplicated root Linux crates, packaging, or release jobs remain after migration.
  Archive historical docs/assets only when needed, with links updated to vendor paths.
- Stop and resolve any unexpected local implementation before replacing files.
  This task does not implement the session, video, or input layers.

Next: [audit-upstream-protocol-and-portability](../02-audit-upstream-protocol-and-portability/README.md).
