# 09 — implement-remote-input

Status: in review; implemented and covered by tests, live Hyprland checks
pending. Dependencies: [07](../07-decode-and-display-h264/README.md).

Results: [implementation record](implementation-record.md).

> Integration: the connection form also carries a video encoder picker
> (`ConnectionRequest.videoMode`, `ServerVideoMode`). It sits in the Server
> section of `ConnectionForm`; keep it when adding keymap/capture settings, and
> keep `videoMode` in the stored `ConnectionRequest` keys next to any keymap field
> (older entries must still decode, see `init(from:)`).

## Outcome

Control the remote desktop through correctly mapped macOS events, with an explicit
keyboard-layout policy and reliable local control release.

## Work

- [x] Capture AppKit events only for the active, focused remote surface. Implement
  key down/up, `flagsChanged`, pointer motion/buttons/drag, scrolling and focus
  transitions. Keep ordinary local controls usable and remove event hooks on teardown.
- [x] Map points through letterboxing, remote view/stream geometry, Retina backing
  scale and `scale_milli` into the server's logical space. Match Linux button and
  scroll axis/discrete/stop semantics; do not send a macOS button bitmask as evdev.
- [x] Define and test a physical macOS keycode-to-evdev table, left/right modifiers,
  repeat, function/media-key policy and shortcut routing. Treat Command/Super,
  Option/Alt and Ctrl explicitly, including reserved macOS shortcuts.
- [x] Prototype with US mapping only if labeled as such. Before release, settle
  local layout parity using a valid XKB map derived/selected for supported macOS
  input sources, including a French layout and dead keys. Detect layout switches
  and send `Keymap` before keys from the new map. Do not claim arbitrary Unicode/
  IME support through the existing physical-key protocol.
- [x] Test ANSI/ISO hardware differences and unsupported input sources. Document
  supported layouts and clear fallback behavior; pursue an upstream optional
  protocol extension only if the existing contract cannot express required behavior.
- [x] Provide a discoverable capture toggle and release shortcut, defaulting to
  Shift+Esc where practical. Verify native app event routing first; if broader
  interception needs Accessibility/Input Monitoring, scope it narrowly and request
  permissions only when enabling that feature. Document OS-reserved exceptions.
- [x] Release pressed keys/buttons on focus loss, disconnect, capture release and
  reconnect. Render remote cursor shape/hotspot/position without double cursors.

## Deliverables and acceptance

- Mapping/coordinate tests and real Hyprland checks cover edges, scaling,
  letterboxing, horizontal/vertical scrolling and drag release outside the view.
- US and French layout checks include text, punctuation, dead keys, modifier chords,
  layout changes and both physical keyboard variants where supported.
- Fullscreen/focus/capture transitions leave no stuck keys or swallowed local UI
  events. The release shortcut works repeatedly and unsupported shortcuts are listed.
- Acceptance evidence distinguishes physical-key support from text/IME support;
  keyboard limitations are visible before a user relies on the connection.

Live checks (US/French text, dead keys, chords, layout switch, scaled output,
scrolling, drag outside, focus transitions and the keymap compiled on the
server), ANSI/JIS hardware and Intel are not verified yet; the record lists them.

From task 06: `SessionController.isCapturingInput`, the ⇧⎋ release
command (`Preferences.releaseShortcut`), the capture preference and focus-loss
release already exist; `RemoteSurface.SurfaceView` is the first responder that
should receive the events. Each window owns its session, so capture is per
window.
