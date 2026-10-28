# 09 — implement-remote-input

Status: planned. Dependencies: [07](../07-decode-and-display-h264/README.md).

## Outcome

Control the remote desktop through correctly mapped macOS events, with an explicit
keyboard-layout policy and reliable local control release.

## Work

- [ ] Capture AppKit events only for the active, focused remote surface. Implement
  key down/up, `flagsChanged`, pointer motion/buttons/drag, scrolling and focus
  transitions. Keep ordinary local controls usable and remove event hooks on teardown.
- [ ] Map points through letterboxing, remote view/stream geometry, Retina backing
  scale and `scale_milli` into the server's logical space. Match Linux button and
  scroll axis/discrete/stop semantics; do not send a macOS button bitmask as evdev.
- [ ] Define and test a physical macOS keycode-to-evdev table, left/right modifiers,
  repeat, function/media-key policy and shortcut routing. Treat Command/Super,
  Option/Alt and Ctrl explicitly, including reserved macOS shortcuts.
- [ ] Prototype with US mapping only if labeled as such. Before release, settle
  local layout parity using a valid XKB map derived/selected for supported macOS
  input sources, including a French layout and dead keys. Detect layout switches
  and send `Keymap` before keys from the new map. Do not claim arbitrary Unicode/
  IME support through the existing physical-key protocol.
- [ ] Test ANSI/ISO hardware differences and unsupported input sources. Document
  supported layouts and clear fallback behavior; pursue an upstream optional
  protocol extension only if the existing contract cannot express required behavior.
- [ ] Provide a discoverable capture toggle and release shortcut, defaulting to
  Shift+Esc where practical. Verify native app event routing first; if broader
  interception needs Accessibility/Input Monitoring, scope it narrowly and request
  permissions only when enabling that feature. Document OS-reserved exceptions.
- [ ] Release pressed keys/buttons on focus loss, disconnect, capture release and
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
