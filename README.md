# Gliff for macOS

A native macOS client for [Gliff](https://github.com/omacom/gliff), connecting to
an existing Linux/Hyprland host over SSH.

This repository currently contains the project foundation: a native app launch
shell, app-owned Rust workspace, the Rust/Swift bridge (UniFFI facade, session driver,
universal XCFramework and Swift package), and pinned upstream source. SSH connections,
video, input and clipboard are subsequent implementation tasks.

## Get started

```bash
gh repo clone Remi-B/gliff-mac
cd gliff-mac
scripts/bootstrap.sh
scripts/check.sh
```

Install Git, Python 3, a C compiler and [rustup](https://rustup.rs/) first. On macOS,
use full Xcode 16.4, selected with `xcode-select` or `DEVELOPER_DIR`; Linux can run
the portable Rust and structure checks. Bootstrap installs the pinned Rust toolchain
and initializes the exact upstream commit, never the latest moving branch.

On a Mac, run `scripts/build-bridge.sh` once (and after Rust changes) before opening
`macos/GliffMac.xcodeproj` with the shared **GliffMac** scheme, or run
`scripts/build-app.sh`, which builds the bridge and an unsigned universal development app.

## Source ownership

- `crates/gliff-client-core`: portable session integration boundary.
- `crates/gliff-mac-core`: app-owned UniFFI facade.
- `tools/uniffi-bindgen`: matching pinned binding generator.
- `macos/`: Xcode app, native Swift code and local `GliffCore` Swift package.
- `vendor/gliff`: unmodified upstream Git submodule; protocol/transport dependencies
  come from here. The Linux server and client stay in their own upstream workspace.
- `scripts/`, `tests/`, `docs/`: app-owned tooling, fixtures and development docs.

The app has independent history and versioning. Frequent upstream adoption updates
the submodule pin, app lockfile when needed, and compatibility evidence. See
[development](docs/development.md), [repository setup](docs/repository-setup.md),
and [upstream attribution](THIRD_PARTY_NOTICES.md).

The [implementation plan](docs/plan.md), original specification and
individual task folders are versioned under `docs/`.

Released under the [MIT license](LICENSE).
