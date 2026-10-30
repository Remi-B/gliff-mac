# 05 — implement-ssh-session

Status: merged; live SSH and Finder transport acceptance passed. Dependencies: [03](../03-automate-upstream-sync-and-compatibility/README.md),
[04](../04-build-rust-swift-bridge/README.md).

## Outcome

Connect securely to an unmodified Linux server and implement the actual Gliff
session lifecycle, delivering validated encoded data through the bridge.

## Work

- [x] Use system OpenSSH and preserve config aliases, username/port, identity files,
  agent use and ProxyJump. Reuse upstream spawning where suitable; isolate a small
  process adapter if GUI requirements need absolute `/usr/bin/ssh`, captured stderr
  or cancellation hooks. Keep framing/serialization in upstream crates.
- [x] Make initial GUI authentication noninteractive key/agent based, with normal
  known-host verification and bounded connection/handshake timeouts. Report missing
  keys, unknown/changed host keys and unavailable agents clearly, with setup guidance.
  Do not disable verification, embed credentials, or assume a GUI has terminal stdin.
- [x] Specify host and remote command validation/quoting. Local argv avoids local
  shell evaluation, but OpenSSH's remote command can still be interpreted by a shell.
  Keep the server path/options structured and do not interpolate UI text into it.
- [x] Own the SSH child until disconnect, drain bounded diagnostics, close pipes,
  cancel/join workers, terminate if needed, and reap it.
- [x] Validate Finder launch with its actual environment rather than assuming
  developer shell PATH/SSH_AUTH_SOCK.
- [x] Implement states for connecting, handshaking, streaming, stopping, closed and
  failed. Handle `Hello`, `HelloAck`, features, fatal version errors, ping/pong,
  `StreamConfig`, frames and cursor messages using task-02 contracts.
- [x] Advertise only implemented H.264/Single420 initially. Forward main/aux metadata
  without silently losing payloads; reject unsupported configurations. Enable
  Dual420 only after task 08's native path passes.
- [x] Serialize outbound commands, prioritize protocol control over bulk transfers,
  and implement native decode-result feedback for `FrameAck`/keyframe requests.
  Bound in-flight bytes and define recovery if native decode stalls or fails.

## Deliverables and acceptance

- Mock-peer tests cover version mismatch, unknown messages, invalid payloads,
  handshake timeout, EOF and cancellation at every startup stage.
- A real key-authenticated SSH session reaches configuration/video delivery against
  the baseline server. Ping/pong and frame feedback allow continued server pacing.
- Host-key/auth failures are actionable; stop/quit leaves no SSH children, active
  callbacks or workers. Repeated connect/stop cycles pass lifecycle checks.
- Diagnostics identify server/version/phase without logging key material or video/
  clipboard contents. No application password store is required for this milestone.

Implementation and verification limits: [implementation record](implementation-record.md).
Follow-ups: [native VideoToolbox decode/display (task 07)](../07-decode-and-display-h264/README.md)
and [SSH multi-hop implementation/live validation (task 12)](../12-validate-performance-and-end-to-end/ssh-multi-hop.md).
