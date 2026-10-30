# Task 09 implementation record

Updated 2026-10-30. Branch `feat/remote-input`, based on merged task 07
`9d33b87103cd47551450096fd638ebfd43d11614`. Implementation is ready for
review; the remaining live and hardware acceptance checks below are open.
Upstream stays unmodified at `58c742452ded3f10a2ce61f60eb4845f18205e29`
(Gliff 0.4.1). No wire extension is needed.

## Preservation and integration

The failed Opus delegate left a clean, pushed commit `6fa64b9` on
`task/remote-input-cursor` in its managed worktree. It was inspected read-only
and cherry-picked into this separately authorized managed worktree. The old
checkout and branch were neither changed nor removed. Sol continued the work
under the user's explicit provider override.

Task 08 owns full-chroma video; task 09 owns input and cursor. This branch
changes neither `FrameGeometry` nor `VideoDisplay`. Task 08's additive
`DecodedFrame.aux`/`isFullChroma`, diagnostics and `postDeferred` remain
compatible. When merging 08 first, retain its `LiveSession.chroma` list in
`LiveSessionFactory`, and add this branch's `keymap` to those options. The Rust
`Keymap` addition is independent of 08's removal of forced Single420. Separate
branch passes do not prove combined Dual420/input acceptance: integration must
rerun the affected app suites and live capture/focus/resize checks.

## Input and cleanup

`RemoteSurface.SurfaceView` forwards native events only while captured, its
window is key and it is first responder. Mouse events use view overrides and a
tracking area; an AppKit local monitor handles key down/up and `flagsChanged`
before menu equivalents. The monitor exists only during capture and is removed
on release, detachment and dismantling. No global event tap or privacy permission
is requested. Ordinary toolbar, menu and local text controls remain available.

Capture is per window: click the surface (when enabled in Settings), use the
keyboard toolbar button, or Connection > Capture Input. The capturing click
stays local. Shift+Escape releases capture and is consumed. The toolbar/menu,
first-responder loss, key-window loss, close, disconnect, reconnect and session
end also release it. `InputForwarder` tracks physical keys and evdev buttons,
drops auto-repeat and unpaired releases, and lifts every held input once.
Teardown releases directly before waiting for a SwiftUI update; active finger
scroll axes also receive stop events if capture ends mid-gesture.

A rejected bridge input breaks ordering: a lost key-up could otherwise leave a
remote key down, and a lost keymap could type with the wrong layout. The
forwarder latches failure, stops forwarding, and the controller cancels the
session and offers reconnect. The pinned server releases input when dropping
its virtual devices. It never silently continues with uncertain held state.

`RemoteSession` adds `send(InputEvent)` and `keyboardLayout` (the map in Hello).
The controller owns one forwarder per session. The bridge and portable driver
add `InputEvent.keymap` / `InputCommand::Keymap`, serialized as the existing
`ClientMsg::Keymap` in the same queue as keys. A Rust mock peer proves ordering.

## Keyboard policy

- Physical macOS virtual key codes map to Linux evdev positions, including the
  ISO Section/Grave swap, left/right Shift, Ctrl, Option/Alt and Command/Super,
  editing/navigation keys, F1–F20, keypad and JIS positions.
- Caps Lock changes send a complete press/release; Fn/Globe and media/system
  keys stay local. F-keys work when macOS delivers them as F-keys. Repeat is
  supplied by the remote compositor.
- Supported sources: U.S., ABC, French and French – PC. Every other source,
  including IMEs, visibly falls back to U.S. Unsupported derivation also falls
  back rather than claiming parity.
- The standard `pc`/`inet(evdev)` definitions supply modifiers and control
  keys. `MacKeymap` derives printable symbols for base, Shift, right Option and
  Shift+right Option from Apple's `UCKeyTranslate` data for the actual keyboard
  type, including XKB dead accents. Stock `us(mac)`/`fr(mac)` symbols alone were
  tested and found inaccurate, especially for Option and French ANSI punctuation.
- Right Option is AltGr for symbols; left Option remains Alt for Linux shortcuts.
  This intentional shortcut policy differs from using either Option key for
  text on macOS. Command is Super, and Ctrl remains Ctrl.
- The map goes in Hello. A source-change notification and a check before each
  key press ensure a changed map precedes keys. Hardware type is part of the
  cache key, so another keyboard's first event can select its derived map.
- This is physical-key support, not Unicode insertion or IME transport. No
  dictation, character/emoji picker, press-and-hold accents or arbitrary composed
  strings. Supported dead accents compose on the Linux client through XKB.

| Shortcut | While captured |
| --- | --- |
| Shift+Escape | Releases locally; never sent |
| App menu Command chords, including Command+Q/W/H/comma | Forwarded as Super chords |
| Command+Tab, Spotlight/input-source hotkeys, Spaces/Mission Control, screenshots, Force Quit, Lock Screen, Fn/Globe/media shortcuts | macOS may reserve them; only events delivered to the app can be forwarded |

The exact reserved set depends on macOS Keyboard Shortcuts settings. No broader
interception or Accessibility/Input Monitoring permission is implemented. Layout
and fallback status are visible on the remote status line before capture, with
physical-key and IME limitations in Settings and help text.

## Pointer and cursor

Pointer mapping inverts the renderer's fitted picture: surface points through
rounded Retina drawable pixels and `FrameGeometry.fit`, then stream pixels
through effective `scale_milli` to remote logical points. Letterbox and outside
positions clamp to the output edge, allowing drag/button-up outside the view.
The mapping follows the last submitted picture, including while a new size
waits for an unavailable drawable. Before a picture there is no mapped motion. Buttons are evdev `BTN_*` codes,
never a macOS bitmask. Wheel axes use 15 logical pixels per detent and discrete
signs, matching upstream; precise scrolling sends finger deltas and stops on
both axes. macOS momentum is dropped, matching the remote kinetic-scroll policy.

Validated cursor shapes are premultiplied BGRA, at most 1024×1024 with an in-image
hotspot. A captured surface uses `NSCursor` at the local pointer for low latency;
there is no second overlay. A released surface draws a real shape at the last
visible `CursorPos` with matching shape ID and hotspot. Cursor positions are full
capture-buffer pixels, so their mapping and image size also account for the
output scale in Hello, independently of encoder downscaling. The
[protocol position contract](https://smithay.github.io/wayland-rs/wayland_protocols/ext/image_copy_capture/v1/client/ext_image_copy_capture_cursor_session_v1/enum.Event.html)
provides these units. Visibility hides the cursor; malformed shapes retain the
last valid one. Cursor movement needs no new video frame.

Hyprland 0.56 shares transparent/flat shapes (see upstream
`docs/hardware-quirks.md`). For these the upstream fallback policy is retained:
hide the local pointer on headless sessions, whose compositor picture can carry
the pointer, and use an arrow on mirrored sessions. No synthetic remote image
is drawn for missing shapes. Hyprland also reports hotspots in logical rather
than image pixels on scaled outputs: this upstream quirk remains a limitation.

## Validation

Local platform: macOS 27.0.1 arm64, Apple M4 Pro, Xcode 27.1, Rust 1.90.0.

| Criterion | Evidence |
| --- | --- |
| App suites | `scripts/test-app.sh`: 96 tests in 16 suites passed |
| Coordinates/buttons/scrolling | `PointerMappingTests`: letterbox/pillarbox corners, clamping, Retina 1/2, effective scale, downscaled cursor coordinates, evdev buttons, wheel/finger axes/stops |
| Keys and layouts | `KeyCodeTests`, `KeyboardLayoutTests`: positions, ANSI/ISO swap, left/right modifiers, unsupported fallback, derivation for ANSI/ISO Apple data, safe Unicode/dead-symbol encoding |
| Release and queue failures | `InputForwarderTests`, `SessionControllerTests`: repeat filtering, keymap ordering, held-state cleanup, reconnect/end, rejected map/release cancels once |
| Focus and lifecycle | `SurfaceInputTests`: capture click, other-window/first-responder/key-window filters, Shift+Escape, drag clamp/release, view detachment |
| Cursor | `RemoteCursorTests`, surface/controller tests: BGRA shape/hotspot scaling, position/visibility/shape IDs, no overlay during capture, clearing on teardown |
| Real keymap compilation | `scripts/export-keyboard-layouts.sh`, `scripts/check-keyboard-layouts.py`: Apple translation data vs Linux libxkbcommon for all four sources and ANSI/ISO data: 1,568 symbol comparisons, 46 dead-accent Compose checks, zero differences; [evidence](evidence/layout-symbols-and-compose.json) |
| Native bridge to Hyprland | Headless smoke below; actual text and dead-key composition asserted |
| Gates/CI | Full gate run and CI recorded on the PR; compatibility qualification is refreshed from clean-source evidence |

### Headless native input smoke

The production `LiveSession`, `H264Decoder`, `InputForwarder`, key table and map
builder were compiled into a temporary Swift probe, linked to the real bridge.
It connected through SSH to the unmodified pinned server (`--stdio --headless`)
on the reserved Omarchy host, launched only a synthetic foot terminal on its
temporary output, and read its input file. Observed output was exactly:

```text
hello [] é
azerty êë
```

This covered a live US-to-French `Keymap`, punctuation and dead acute,
circumflex and diaeresis. It sent 63 accepted inputs, decoded 121 frames, and
received 3 cursor positions and 5 shapes. Button/drag release, wheel axes,
finger deltas and stops were sent; their visual effects were not asserted.
No held state remained. [Machine-readable evidence](evidence/native-input-smoke.json).
This was a development-tree smoke, not clean-source
compatibility qualification or a native UI/hardware acceptance claim.

Cleanup verified no probe server, no task-09 terminal and only physical `eDP-1`.
The host was explicitly released to task 08 before further live work.

Repeat the read-only symbol/Compose validation (requires the existing Linux
libxkbcommon, but does not access a compositor/GPU/server or write remote files):

```bash
scripts/export-keyboard-layouts.sh
python3 scripts/check-keyboard-layouts.py build/input-layouts/layouts.json \
  --ssh remi@omarchy-mbp.local --identity ~/.ssh/id_ed25519_omarchy
```

## Remaining acceptance and limits

- Native UI capture/release and repeated Shift+Escape, local Command routing,
  fullscreen/focus transitions, actual drag outside the window and visual scroll
  effects still need an interactive live check. Synthetic AppKit tests prove the
  routing logic; the native smoke bypasses the surface event monitor.
- Scaled live output and actual ANSI/ISO physical hardware remain unverified.
  Both translation tables were tested; that is not physical hardware evidence.
  JIS/external PC hardware and Intel runtime are unverified.
- Local Caps Lock state already active before capture is not synchronized; toggle
  it while captured to change the remote state. Custom modifier remapping is not
  derived. Shift/Option/Super already held before capture should be released and
  pressed again. The supported symbol levels are base/Shift/right Option/Shift+
  right Option, not a promise of every system text transformation.
- Output scale is taken from Hello; external scale changes need a new session.
  Task 10 owns display reconfiguration/reconnection qualification.
- Transparent cursor images and scaled hotspots retain the upstream Hyprland
  limitations above. Real nontransparent remote shapes were fixture-tested;
  the live host did not supply useful shape pixels.
- Task 08 must merge first, followed by shared session wiring resolution and
  combined Single420/Dual420 input/cursor validation. Neither branch is merged
  or watched by this task.
