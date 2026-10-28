# Repository and integration architecture

Status: selected; GitHub replacement and local foundation implemented, Apple
validation pending. Updated: 2026-10-28.

## Decision

Maintain `gliff-mac` as an independent macOS application repository, with the full
upstream Gliff repository pinned at `vendor/gliff` as a Git submodule. App-owned
Rust crates depend on selected upstream library crates by path. Swift consumes
only our UniFFI API and native media abstractions. The Linux server remains an
upstream product installed/built on Linux.

User direction on 2026-10-28 supersedes the original in-place migration proposal:
delete the fork and create a new independent `Remi-B/gliff-mac` repository with
the same name. Start fresh app history and preserve the original checkout/history
as local backups. The user recreated the independent public repository directly,
resolving the GitHub CLI's earlier deletion-scope blocker. The old local app folder
was removed and replaced with a fresh `gh repo clone` of the new repository; the
foundation is reapplied on its new license-initialized history.

## Evidence from the current code

The original fork tree and upstream `main` were checked at
[`58c742452ded3f10a2ce61f60eb4845f18205e29`](https://github.com/omacom/gliff/commit/58c742452ded3f10a2ce61f60eb4845f18205e29),
release 0.4.1. These source paths now live under `vendor/gliff/` in the independent
application checkout:

- `Cargo.toml`: one Linux-oriented workspace with GTK/Wayland/VA-API/Vulkan crates;
  there is no `gliff-core` library.
- `crates/gliff-proto`: CBOR messages, payload limits, compatibility rules and CPU
  reference algorithms. It does not own I/O.
- `crates/gliff-transport`: Tokio framing, SSH spawning, clipboard transfer engine
  and file spool. Its manifest has no direct GTK/Wayland dependencies. This is a
  promising portability boundary, not proof of a successful macOS build.
- `crates/gliff/src/net.rs`: useful session behavior intertwined with Linux decoders,
  GPU/DMABUF frames, keymaps and the Linux client's clipboard/UI adapter.
- `crates/gliff/src/keymap.rs`: observes a Hyprland keymap. It cannot supply the
  local macOS keyboard layout.
- `.github/workflows/ci.yml`: Linux checks and a Linux-oriented release pipeline.

## Alternatives considered

**Keep a long-lived fork with the macOS app in upstream's root workspace.**
Initially simple and useful if upstream has agreed to maintain the macOS app
directly. Here every root workspace/CI/build change would be in the merge path of
frequent upstream synchronization. Linux client implementation details would be
tempting dependencies. Rejected for the current independent app; revisit if Gliff
adopts a native macOS frontend upstream.

**Independent app with Cargo Git dependencies pinned by `rev`.**
A strong alternative with less checkout/bootstrap machinery. Cargo can locate
multiple crates within one repository and pin them to a revision. Prefer this if
only published-style Rust APIs are needed. We currently also need the complete
server source, reference implementations, upstream fixtures/tests, and a coherent
revision for a Linux compatibility harness. A visible submodule gives all of these
one source pin and makes upstream investigation and comparison straightforward.
This is an operational choice, not a claim that Git dependencies are less
reproducible. Revisit once the portable upstream API and test artifacts stabilize.

**Independent app with a pinned upstream submodule — selected.**
It separates update ownership without duplicating source. An update is a gitlink
change with adapter/test adjustments; independent app commits never conflict with
upstream UI, packaging or root workspace changes. Costs include recursive checkout,
nested-workspace discipline, and keeping parent/upstream lockfiles distinct. Scripts
and CI must enforce these rules.

**Copy/subtree upstream source or reimplement the protocol in Swift.**
Both remove the submodule setup step, but copied source invites unnoticed drift,
subtree updates mix source histories, and a second wire/transfer implementation
increases update effort. Rejected. The submodule still does not make the embedded
client session loop a public portable API: our small adapter needs behavioral tests.

## Target layout

The local foundation follows this layout. Native bridge generation and session
implementation remain later tasks:

```text
gliff-mac/
  .gitmodules
  Cargo.toml                 # app-owned workspace; exclude vendor/gliff
  Cargo.lock                 # resolved app dependencies, committed
  rust-toolchain.toml
  vendor/gliff/              # gitlink to omacom/gliff; clean, independently owned
  crates/
    gliff-client-core/       # session state/protocol adapter, no Apple or Linux UI
    gliff-mac-core/          # UniFFI facade; rlib + staticlib, optional bindgen dylib
  tools/uniffi-bindgen/      # pinned generator matching bridge runtime
  macos/
    GliffMac.xcodeproj/      # checked-in project and shared schemes
    GliffMac/                # SwiftUI/AppKit app, media, input, pasteboard
    GliffMacTests/
    Packages/GliffCore/      # local Swift package; generated Swift/C binary wiring
  scripts/                  # bootstrap, check, build, upstream update, e2e
  tests/fixtures/            # protocol/video/colour fixtures and provenance
  docs/                      # specification, plan, tasks and development docs
```

The original specification, plan and task folders are versioned in this repository
under `docs/`.

The parent workspace names only its own crates/tools as members. Explicitly
exclude the vendor workspace and verify path dependency inheritance using
`cargo metadata` on real macOS targets. App manifests use paths into
`vendor/gliff/crates/gliff-proto` and `vendor/gliff/crates/gliff-transport`; upstream
crates continue inheriting metadata/dependencies from their own workspace. Do not
add the bridge as an upstream member or copy upstream `[workspace.dependencies]`.
See [Cargo dependency rules](https://doc.rust-lang.org/cargo/reference/specifying-dependencies.html).

Commit the parent's `Cargo.lock`, including resolved transitive upstream library
dependencies. Upstream's lockfile governs builds of the separate Linux workspace;
it does not pin dependencies in the app workspace. Record both in test evidence.
Use `--locked` in checks/releases and controlled lockfile refreshes during updates.

## Runtime and API ownership

1. Swift owns app lifecycle, native UI, focus, VideoToolbox/Metal objects and
   pasteboard. macOS event codes never go directly onto the wire.
2. `gliff-mac-core` exposes app-owned records, typed errors and session handles.
   UniFFI generation is isolated here. Do not expose every upstream message as
   public Swift API, or decode/serialize CBOR in Swift.
3. `gliff-client-core` owns asynchronous session state, SSH process lifetime,
   handshake/configuration, validated payload forwarding, input commands, frame
   feedback and transfer orchestration. It reuses upstream protocol/transport code.
4. Adapt only orchestration that is trapped in upstream's Linux binary. Record the
   source SHA and behavior inventory beside that adapter; compare changes to those
   source paths on every bump. No maintained copies of framing, rate control,
   reference colour code, or clipboard transfer machinery.
5. Prefer an upstream portable session API when available. Small portability hooks
   should be proposed upstream; avoid making its future acceptance a delivery blocker.

Use explicit lifecycle/cancellation and generation identifiers, ordered stream
configuration/video delivery, bounded byte budgets, and decode acknowledgments.
An FFI `Vec<u8>` may copy compressed data; measure that before introducing unsafe
zero-copy interfaces. Keep pixel buffers and GPU textures on the Swift/native side.

## Updating upstream and handling exceptions

Normal builds initialize the exact gitlink, never `main` at build time. Candidate
updates fetch upstream, choose a full commit SHA, compare changed contract/session
paths, update the gitlink and app lockfile when necessary, and run compatibility
gates. Retain the previous passing pin for immediate rollback. Git documents this
[third-party submodule workflow](https://git-scm.com/docs/gitsubmodules).

Default to zero upstream patches. If a necessary portability fix cannot be done
in the app adapter, use an explicitly documented temporary patch branch/fork:
record upstream base, patch commits, rationale, upstream PR/issue if one exists,
rebase procedure and removal condition. Pin the resulting commit and report the
divergence in provenance. Do not apply hidden edits in bootstrap/build scripts or
claim that patched source is the unmodified upstream baseline. This exception
must never turn into a second maintained Linux client/server.

## Migration and reversibility

Task 01 inventories the original checkout and preserves its full directory, an
all-refs bundle and a named baseline tag before replacing the local app checkout.
The new app root starts independent history, and the original Gliff tree appears
only in the pinned submodule. Planning docs are versioned under `docs/`.

The user recreated the remote directly. The fresh GitHub clone retains its initial
license commit/default branch, with the app foundation reapplied locally. The
foundation remains unpublished; no repository deletion or token refresh is needed.
Backup paths and current checkout state are recorded in the implementation record. A source bundle
preserves Git source/history; it does not restore deleted GitHub metadata.

Later upstream rollback uses a normal revert/revert series and
`git submodule update --init --recursive --checkout` for the selected parent commit.
Bootstrap was validated with ordinary and recursive local clones and is rerun on
the new GitHub checkout. Apple build validation remains a separate gate.

## Consequences and review triggers

The app can release independently and adopt upstream by a small pin change. It
still needs Rust API adaptations, native rendering/input work, real Mac hardware,
and Linux interoperability tests. A shared protocol version is not sufficient
proof. Reconsider this decision if upstream offers a maintained portable client
library, accepts the macOS app directly, submodule overhead becomes disproportionate,
or patch divergence repeatedly blocks upgrades. Those are reasons to change the
dependency mechanism, not to duplicate protocol logic.
