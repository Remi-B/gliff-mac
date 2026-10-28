# 06 — create-native-macos-app

Status: planned. Dependencies: [04](../04-build-rust-swift-bridge/README.md).

## Outcome

A native macOS application shell that owns connection state and presents a remote
surface. Use a fake session implementation until task 05 is ready.

## Work

- [ ] Implement SwiftUI app/windows with AppKit integration for the remote surface.
  Use a checked-in Xcode project/shared scheme and the local `GliffCore` package.
- [ ] Define a main-actor view model with per-session identity and explicit
  connecting/streaming/reconnecting/error/stopped states. Keep networking and decode
  work out of SwiftUI view construction and updates.
- [ ] Provide host/config alias, optional username/port/identity selection, server
  path/options, connect/disconnect and clear validation errors. Reflect key/agent
  authentication; do not ship the source spec's ambiguous password/private-key field.
- [ ] Add a remote-surface placeholder, connection progress, error recovery actions,
  preferences for clipboard/input capture, and a discoverable release shortcut.
  Show unsupported/reduced-quality states honestly.
- [ ] Define close-window, app quit, reconnect and view replacement teardown. Keep
  native state per session so a future second window/tab cannot share input or
  clipboard ownership accidentally. Initial release may show one session at a time.
- [ ] Persist only connection metadata/preferences with clear forgetting behavior;
  do not store credentials in recent hosts. Use standard macOS accessibility labels,
  focus behavior, keyboard navigation and light/dark appearance.
- [ ] Document initial direct distribution outside App Sandbox. Verify subprocess,
  SSH config/agent and filesystem behavior in a built app; signing/hardened runtime
  is finalized in task 13. Avoid unused incoming network or capture entitlements.

## Deliverables and acceptance

- A documented `xcodebuild` invocation builds the app from a clean generated bridge.
- UI state tests using a fake session cover failure, cancellation, stale callbacks
  and window closure while connecting. Main-actor checks remain clean.
- The app launches from Finder, supports native resizing/fullscreen and accessible
  connection controls, and releases its session on disconnect/quit.
- When task 05 lands, the same view model connects to its real implementation
  without exposing upstream protocol types to SwiftUI.
