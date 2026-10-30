# Task 06 implementation record

Updated: 2026-10-30. Branch `feat/native-macos-app`. Status: in review.
Dependency 04 is merged, and so is task 05: the app uses the real SSH session,
and its tests use a fake. Upstream remains the unmodified pinned
`58c742452ded3f10a2ce61f60eb4845f18205e29` (`gliff-server 0.4.1`).

## Delivered behavior

`macos/GliffMac` is a SwiftUI app with AppKit where SwiftUI is not enough: the
remote surface `NSView`, the window-close observer, the identity file panel and
the quit handshake. The checked-in project uses file-system synchronized
folders (`objectVersion` 77, Xcode 16+), so new Swift files need no project edits.
The shared **GliffMac** scheme builds the app and runs the new hosted
`GliffMacTests` bundle; both link the local `GliffCore` package.

| Piece | Role |
| --- | --- |
| `Model/ConnectionRequest` | Host/alias, optional user, port, identity file path and server path, headless toggle. Field validation mirrors the bridge's own; the bridge validates again |
| `Model/RemoteSession` | `RemoteSession`/`SessionFactory` protocols; `LiveSession` wraps `GliffSession` + `SessionRelay` |
| `Model/SessionRegistry` | Owns every started session until its `.ended`, whatever happens to its window; quit cancels all and waits with a deadline |
| `Model/SessionController` | Main-actor view model per window: phases, actions, stale-callback filtering, input-capture state |
| `Model/SessionFailure` | Maps typed `GliffError`s to a title, message, fatality and recovery actions |
| `Model/RecentConnections` | Recent destinations in `UserDefaults`, forget one/all, remembering on/off |
| `Views/*` | Connection form and recent hosts, progress, failure, remote surface, Connection menu, Settings |

### State and identity

Phases: `idle`, `connecting(step)`, `reconnecting(step)`, `streaming(info)`,
`failed(failure)` and `stopped(reason)`. The step distinguishes SSH and server
startup from waiting for the first video configuration. Each attempt gets a
new `SessionID`, and events carry it. The controller ignores events from any
other session, and every event after its window closed, so a replaced,
disconnected or closed session cannot change the window's state. Reconnect
cancels the previous session before starting a new one with the same settings.
Fatal incompatibilities offer only "Edit Connection"; other failures also
offer "Try Again".

SwiftUI views see only the controller's own types (`Phase`, `StreamInfo`,
`SessionFailure`, `ConnectionRequest`). Bridge records stop at the controller,
and no upstream `gliff-proto` type reaches Swift at all. Networking, decoding
and teardown stay in the bridge; the controller only reacts to main-actor
events and never blocks. The app target compiles in the Swift 6 language mode
with complete concurrency checking, with no warnings.

### Teardown

| Event | Behavior |
| --- | --- |
| Disconnect | Cancel and show "Disconnected" at once; the late `.ended` is ignored |
| Reconnect / view replacement | Cancel the old session and start a new one; stale events ignored |
| Window close | `NSWindow.willCloseNotification` and `onDisappear` both call `close()`: cancel, then freeze the window's state |
| App quit | `applicationShouldTerminate` returns `.terminateLater`, cancels every registered session and replies once all have ended, or after 5 s |

The registry, not the window, retains a session until `.ended`, which the
bridge sends after reaping SSH. The session holds its controller weakly, so a
closed window's controller is released immediately. Every window has its own
controller and session, so input capture (and clipboard ownership in task 11)
cannot be shared between windows by accident. The app opens one session per
window, and File › New Gliff Window opens another independent one.

### Connection form, authentication and persistence

The form reflects key/agent authentication: an optional identity file chosen
with an open panel (only its path is kept), plus a note to verify the host key
in Terminal first. There is no password or private-key text field. Recent hosts
are remembered only after the server answered. They store only the request
fields (host, user, port, identity path, server path, headless), with a test
asserting the encoded keys. Users can forget one host (context menu), all hosts
(the list or Settings), or turn remembering off, which forgets everything.

### Placeholder, preferences and honest states

The remote surface is a layer-backed `NSView` that accepts first responder; it
will host the Metal layer (tasks 07–08) and native input (task 09). Until the
decoder exists, `LiveSession` consumes frames without decoding them and
reports them `decoded`, so the server keeps pacing. Reporting them `discarded`
would trigger a keyframe request after every frame. The surface says video is
received but not displayed yet. The status bar shows the size, virtual or
mirrored display, and "Reduced colour (4:2:0)" for Single420. Non-fatal server
errors appear in the status bar.

Clicking the surface captures input when the preference allows it. Capture
ends with the release shortcut, window focus loss, disconnect or any session
end. The release shortcut is **⇧⎋** (Connection › Release Input), task 09's
default. It is shown in the status bar and in Settings. The menu item is enabled
only while capturing, so ⇧⎋ still reaches local controls otherwise. Task 09 must
consume it locally and never forward it. Keys and the pointer are not sent yet, and the surface says so.
The clipboard sharing preference exists but is disabled, with "not available
yet".

Accessibility: labelled fields, inline error labels, an accessible surface
value (size, video, colour, capture state) and buttons with help text. Keyboard
navigation uses default (↩) and cancel (⎋) buttons, ⌘↩ Connect, ⌘R Reconnect
and ⇧⌘D Disconnect, and focus starts on the host field. System colours and
materials follow light and dark appearance.

### Distribution and permissions

The app is distributed directly, outside the App Sandbox. Hardened runtime stays
on, with no entitlements: no incoming network, camera, screen-capture or
Apple-events entitlement. Signing and notarization are task 13.
`NSLocalNetworkUsageDescription` was added after the live run found that macOS
Local Network privacy blocked the Finder-launched app's `/usr/bin/ssh` child
from reaching a `.local` LAN host. SSH fails at once with "could not reach the
host" until the user allows Gliff in System Settings › Privacy & Security ›
Local Network. A public host was reachable without it. Running the binary from
Terminal works without the grant because Terminal is the responsible process,
so GUI acceptance must use Finder/LaunchServices.

Debug builds only: `DebugAutoConnect` reads a JSON `ConnectionRequest` once from
the `GliffDebugAutoConnect` default, removes it and connects. Live checks use it
to drive a Finder-launched app without UI scripting. It is compiled out of
Release. Lifecycle logs (`com.remi-b.gliff-mac`, categories `session` and
`lifecycle`) record phase names, sizes, session identifiers and the bridge's
fixed failure guidance. They never record hosts, users or paths.

## Acceptance evidence

macOS 27.0.1 arm64, Xcode 27.1, Rust 1.90.0.

| Criterion | Evidence |
| --- | --- |
| Documented `xcodebuild` from a clean generated bridge | `scripts/build-app.sh` (regenerates the bridge, universal arm64 + x86_64 Debug build) and `scripts/test-app.sh`; gates `macos-app` and the new required `app-tests` |
| UI state tests with a fake session | 30 Swift Testing tests in 6 suites: steps to streaming, field validation, start/make failures, transport and fatal failures, server close/errors, cancellation while connecting with late callbacks, reconnect with stale events, window close while connecting, controller release, input capture, recent-host persistence/forgetting/metadata, quit drain and deadline, error mapping and readable messages |
| Main-actor checks | Swift 6 mode, complete checking, zero app warnings; the view model, registry and stores are `@MainActor`, and events arrive through `SessionRelay`'s main-queue delivery |
| Same view model on the real implementation | Hosted tests drive `LiveSession` over recorded server streams (streaming then closed, 20 connect/disconnect cycles, unsupported Dual420 → fatal). Live Finder run below |
| Finder launch, live SSH, release on disconnect/quit | See the live run below |
| Native resizing/fullscreen | View › Enter Full Screen took the Finder-launched window from 997×643 to 1728×1084 points and back; minimum content size 640×420 |

### Live Finder run

The app was launched with the Finder Apple event (parent `launchd`, PATH
`/usr/bin:/bin:/usr/sbin:/sbin`, GUI `SSH_AUTH_SOCK` present). It connected to
the unmodified pinned server on `omarchy-mbp.local` with a headless virtual
display; the menu actions were clicked through System Events:

| Time | Event | Processes |
| --- | --- | --- |
| 01:34:28.217 | `connecting(starting)` session-1 | |
| 01:34:40.394 | `connecting(awaitingVideo)` | |
| 01:34:40.401 | `streaming(1920x1080)` | one app-owned `/usr/bin/ssh`; one remote `gliff-server --stdio --headless` |
| 01:34:54.059 | Disconnect → `stopped(disconnected)` | no local SSH child; no remote server |
| 01:34:59.310 | Reconnect → `reconnecting(starting)` session-2 | |
| 01:35:09.936 | `streaming(1920x1080)` | one new SSH child |
| 01:35:21.470 | Quit: cancelling 1 session | |
| 01:35:21.557 | Quit: sessions ended cleanly (87 ms) | app gone; no local SSH; no remote server |

The Terminal-launched run (before the Local Network grant) also streamed
1920×1080 and quit cleanly in 77 ms with no SSH left.

## Independent review

Sol (GPT, high effort) found no significant issue in session ownership, stale
callbacks, the quit continuation, actor isolation, validation and injection,
credential persistence, forgetting, or placeholder pacing. It reported two
findings:

1. P1: the new required `app-tests` gate makes `scripts/upstream.py check` fail
   until the current-pin record is re-qualified. This was expected and handled
   by the separate qualification commit, from clean local, CI and live evidence.
2. P3: the generated `GliffError.localizedDescription` is `String(reflecting:)`,
   so incompatible-server and internal failures would show Swift type syntax.
   This was confirmed and fixed: every message is now written explicitly, with
   protocol versions and the server code. The regression test
   `messagesAreWrittenForPeople` covers every error case.

## Limits

- Video is not decoded or displayed (task 07). The placeholder reports frames
  `decoded` for pacing only, and the UI says so.
- Input forwarding, cursor rendering and keyboard layouts are task 09. Capture
  is state only, with the release shortcut reserved.
- Clipboard (task 11) and display-mode switching, automatic reconnection and
  resize (task 10) are not implemented. Reconnect is the user's action.
- Live window resizing by dragging was not automated: AX window access is
  unavailable from this shell. Fullscreen was verified, and the window uses
  standard `WindowGroup` resizing.
- Window close during a live connection is covered by the fake-session and
  replay tests, not by a live run.
- Intel runtime and the x86_64 test bundle remain unverified on this Apple
  silicon Mac. The universal app builds.
