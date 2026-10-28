# Repository setup decision

The user requested a fresh independent `Remi-B/gliff-mac` repository under the same
name as the original fork. Its root history starts with the new GitHub license
initialization, followed by the macOS application foundation. Upstream history is
retained exclusively inside `vendor/gliff` rather
than merged into the app's root.

The user recreated the independent public GitHub repository directly. Its default
branch is `master`; app CI checks pushes on all branches. The old local app folder
was removed and replaced with a fresh `gh repo clone` of the new repository. The
prepared foundation was then reapplied while preserving the new repository's license.

The original fork checkout, an all-refs fork Git bundle, and the prepared local
foundation bundle are retained in the shared Gliff workspace as migration backups.
They do not become ancestor commits in this new app history. The implementation
plan, original specification and task folders are versioned in this repository's
`docs/` directory.

## Upstream boundary

The initial upstream commit is
`58c742452ded3f10a2ce61f60eb4845f18205e29` (Gliff 0.4.1). `.gitmodules` points at
`https://github.com/omacom/gliff.git`, the gitlink pins the commit, and
`upstream-revision` records it for build provenance and validation. The redundant
record is checked against the actual gitlink so it cannot silently drift.

The app directly depends only on `gliff-proto` and `gliff-transport` from that
source. Upstream owns Linux capture, input injection, rendering, packaging and
server behavior. App-owned session orchestration will adapt the Linux client's
behavior without importing its platform stack. Swift owns native media/UI/input.

The tradeoff is recursive checkout and explicit source-pin/lockfile ownership.
It avoids recurring fork merges through root Cargo/CI/UI files, keeps complete
upstream source available for compatibility work, and supports a later switch to
an upstream portable client API without changing the native app's public API.

## Recovery

Before a setup change is published, the old checkout/bundle can restore its exact
local state. That backup restores Git source/history; deleting a GitHub repository
also affects GitHub metadata and cannot be reversed by a source bundle.

After the new foundation is established, ordinary upstream rollbacks revert the
parent update commit(s), including gitlink, provenance, app lockfile and adapter
changes together. Run `git submodule update --init --recursive --checkout`, rebuild
generated artifacts and rerun checks. Never force-push released app history or
switch only the vendor commit while leaving incompatible app code behind.

The [architecture decision](01-setup-project-structure/architecture-decision.md)
and task records supersede the initial proposal to preserve the fork's history in
the new application repository.
