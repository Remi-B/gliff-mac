# 02 — audit-upstream-protocol-and-portability

Status: planned. Dependencies: [01](../setup-project-structure/README.md).

## Outcome

Prove the reuse boundary against actual upstream source and the Apple toolchain
before implementing the public bridge. Produce the executable contracts used to
detect upstream drift. No successful macOS build is assumed from manifest inspection.

## Work

- [ ] Build/check the parent-selected `gliff-proto` and `gliff-transport` dependency
  graph for `aarch64-apple-darwin` and `x86_64-apple-darwin` on macOS. Inspect Cargo
  metadata/tree for accidental GTK, Wayland, VA-API, Vulkan/DRM or Hyprland dependencies.
  Verify the selected deployment target and toolchain from task 01.
- [ ] Inventory `msg.rs`, `frame.rs`, transport framing/SSH/clipboard code, and the
  client `net.rs` state machine. Document each behavior reused directly or adapted,
  with source paths, symbols and baseline SHA. Check licenses/attribution.
- [ ] Record framing (8-byte little-endian lengths, CBOR body, out-of-band payloads),
  size limits, unknown-message handling, fatal compatibility errors, `Hello` /
  `HelloAck`, feature negotiation, initial ping/pong and subsequent configuration.
- [ ] Define a session/video contract including configuration generation, geometry,
  scale, frame ID, `pts_us`, keyframe and main/aux bytes. Verify H.264 Annex B,
  SPS/PPS and extradata behavior with real CPU- and GPU-encoded server samples.
- [ ] Specify when the native asynchronous decoder reports completion and when
  Rust sends `FrameAck`; preserve upstream pacing and measure the behavior. Define
  separate presentation timing, queue budgets, keyframe recovery, and disconnect rules.
- [ ] Record evdev/XKB input semantics, logical coordinates, cursor payloads,
  headless/mirror setup, and clipboard offer/request/ack/cancel behavior.
- [ ] Add a minimal mock peer/replay harness using upstream framing and real server
  captures. Store safe synthetic fixture content, generation commands, server SHA,
  settings, expected decoded output/metadata and checksums. Keep hardware-only tests
  separate from deterministic fixtures; do not copy upstream test suites wholesale.

## Deliverables and acceptance

- A checked-in contract/behavior inventory and fixture manifest, including the
  provisional API records needed by task 04 and compatibility cases for task 03.
- macOS build logs for both targets prove the selected dependency graph compiles
  without the Linux client stack. Any failure is resolved through a narrow adapter
  or the architecture's documented portability-patch exception before proceeding.
- Replay checks cover partial reads/writes, oversized/truncated payloads, unknown
  messages, version mismatch, configuration changes and main/aux association.
- At least one real `Single420` and one `Dual420` capture can be parsed without a
  live Hyprland session. Their provenance identifies the exact generating server.
- No unsupported codec/chroma/layout capability is inferred from an enum existing.

Next: [upstream compatibility automation](../automate-upstream-sync-and-compatibility/README.md)
and [Rust/Swift bridge](../build-rust-swift-bridge/README.md).
