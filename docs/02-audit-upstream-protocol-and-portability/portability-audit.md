# Portability audit

Run with `scripts/audit-portability.sh` (also part of `scripts/check.sh` on macOS). It
builds `gliff-client-core` and `gliff-mac-core` in release for both Apple targets with
`MACOSX_DEPLOYMENT_TARGET=13.0`, resolves their normal and build dependency trees,
fails on any Linux client/compositor/GPU/encoder crate, and checks the built archives.
Logs and trees are written to `build/portability/` (not committed).

## Result on 2026-10-28

```text
upstream: 58c742452ded3f10a2ce61f60eb4845f18205e29
host: Darwin arm64; 27.0.1
toolchain: rustc 1.90.0 (1159e78c4 2025-09-14); cargo 1.90.0 (840b83a10 2025-07-30)
xcode: Xcode 27.1 Build version 27A9275
MACOSX_DEPLOYMENT_TARGET=13.0

== aarch64-apple-darwin ==
build: ok
resolved crates (normal+build): 58, none forbidden
upstream crates: gliff-proto gliff-transport
staticlib: arm64        dylib: arm64        minos 13.0, sdk 27.0

== x86_64-apple-darwin ==
build: ok
resolved crates (normal+build): 58, none forbidden
upstream crates: gliff-proto gliff-transport
staticlib: x86_64       dylib: x86_64       minos 13.0, sdk 27.0
```

Forbidden prefixes: `gtk gdk glib gio gobject cairo pango libadwaita wayland- xkbcommon
calloop hypr- drm gbm libva ash vulkan gliff-vk gliff-va gliff-sw gliff-server openh264
dbus`. The structure check applies the same rule to the whole app workspace graph.
`gliff-proto` and `gliff-transport` have no platform-specific dependencies: `minicbor`,
`thiserror`, `rayon`, `tokio`, `bytes`, `tracing`. No portability patch or adapter was
needed to compile; the dependency boundary chosen in task 01 holds.

Toolchain note: this run used Xcode 27.1 on macOS 27 (Apple Silicon), the machine
available, not the Xcode 16.4 that CI selects. The Rust toolchain is the pinned 1.90.0
with both Apple targets installed by `scripts/bootstrap.sh`. The x86_64 slice was
compiled and inspected, not run; Intel runtime evidence remains task 12's.

## Behavioural differences found

| Area | Upstream behaviour | Effect on macOS | Resolution |
| --- | --- | --- | --- |
| Clipboard spool sweep | `files::process_alive` tests `/proc/<pid>` | No `/proc`: `Spool::create_in` deletes the spool of **every other live process** under the same base | Pinned by `tests/portability.rs`. Task 11 gives each app process its own spool base under `~/Library/Caches/<bundle id>/clipboard/<pid>-<launch>` and cleans it itself; propose `kill(pid, 0)` upstream |
| Clipboard spool location | `GLIFF_CLIPBOARD_DIR`, else `$XDG_CACHE_HOME` or `~/.cache/gliff/clipboard` | Not the macOS cache location | Pass the base explicitly (`Spool::create_in`) |
| ssh spawn | `ssh` from `PATH`, stderr inherited | Finder-launched apps get a minimal `PATH`; stderr is lost | Task 05: resolve `/usr/bin/ssh`, capture stderr for error reporting; keep `--` host separation |
| Keyboard | evdev codes + XKB keymap text | macOS has neither | Task 09 mapping; empty keymap means server US layout |
| Video decoding | `net.rs` decodes with Vulkan/VA-API or OpenH264 | Not portable, not used | VideoToolbox (task 07), Metal recombination (task 08) |

Not affected: framing, CBOR, limits, clipboard state machines (`gliff-proto`), and the
transfer engine itself, which only needs a tokio `LocalSet`.
