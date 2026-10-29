# Task 05 implementation record

Updated: 2026-10-29. Branch `feat/ssh-session`. Status: in review;
live SSH and Finder transport acceptance passed.

## Implementation

The UniFFI session now starts absolute `/usr/bin/ssh` with piped stdio and
noninteractive key/agent authentication, strict ordinary known-host verification,
10-second connection timeout and one attempt. Config aliases, user, port,
identities and ProxyJump remain OpenSSH's responsibility. Explicit optional
absolute identity paths support GUI agents that lack the intended key. No SSH
config or vendor changes are made. Forwarding, local commands and multiplexed
control sockets are disabled for this transport.

Host/user fields use restricted syntax and reject option prefixes; server paths
reject control/whitespace and option prefixes. The executable is POSIX shell
quoted (including embedded apostrophes), with structured `--stdio` and optional
`--headless`; there is no raw command/flags API. Local arguments never pass
through a shell. Existing SSH config is trusted user configuration.

The adapter owns the child, closes driver pipes, kills/reaps it, and joins its
stderr worker before returning an end item. Stderr is drained continuously with
16 KiB retained; only fixed redacted host-key/authentication/setup guidance crosses
the bridge. An inherited stderr descriptor has a one-second drain deadline,
after which the task is aborted and joined. Callback delivery/order and the
portable protocol driver remain shared with replay.

`state()` exposes connecting (constructed), handshaking (started), streaming
(first StreamConfig accepted), stopping, closed and failed without changing delegate APIs.
Live support is H264/Single420 regardless of replay decoder preferences; Dual420
fixtures remain supported. Startup has a 20-second bound through the first StreamConfig, including blocked
Hello writes and a server that acknowledges Hello without configuring video. A frame pending native completion for 15 seconds fails the session with
a transport timeout (watchdog resolution 100 ms), also interrupting blocked writes
or delivery. This chooses termination rather than unbounded decode back-pressure;
normal decode failure still uses ordered ack/keyframe recovery.

## Verification performed in the prepared checkout

- Bootstrap completed; upstream pin and submodule sources unchanged.
- `cargo test --workspace --locked`: 44 tests passed, including existing adversarial
  protocol/replay/driver coverage and new process, quoting, redaction, silent/blocked
  startup and decode-stall tests. Process tests flood stderr and repeat lifecycle
  cleanup eight times; cancellation exercises a sleeping child during startup.
- `cargo clippy --workspace --all-targets --locked -- -D warnings`: passed.
- `cargo fmt --all --check`: passed.
- `scripts/build-bridge.sh`: passed; arm64/x86_64 archives, matching generated
  bindings and universal XCFramework regenerated via existing build integration.
- `swift test --package-path macos/Packages/GliffCore`: nine tests passed,
  including SSH pre-start cancellation and state through generated bindings.
- `swift build --package-path macos/Packages/GliffCore --arch x86_64 --build-tests`:
  passed (build only; no Intel runtime claim).
- `python3 scripts/gates.py --only structure,whitespace,ssh-session`: three passed.
  The new SSH gate explicitly covers process/mock behavior, not live acceptance.

## Validation limits

The probes synthetically report decode completion; actual VideoToolbox decoding
remains task 07. Intel runtime and additional agent/ProxyJump configurations are
not covered on this Apple Silicon machine. Host-key/auth classifications have
deterministic unit coverage; destructive changes to real known_hosts were not
used for fault injection. Independent review and current-source CI results are
recorded on the pull request.

## Integration corrections

- Preserve typed protocol/version failures even when server startup logs appear
  on SSH stderr; transport diagnostics cannot hide fatal incompatibility.
- Allow the child a bounded 200 ms normal exit after protocol EOF, check its exit
  status, and accept routine stderr on a successful close.
- Distinguish remote executable permission errors from SSH key rejection, and
  give network timeout/resolution guidance without exposing raw diagnostics.
- Keep the startup deadline active after HelloAck until StreamConfig; the public
  state remains handshaking during server video setup. Regression tests exercise
  both logged protocol rejection and a logged clean close, plus silent setup
  after HelloAck.

## Parent live acceptance

The public facade reached the unmodified pinned `gliff-server 0.4.1` on the
Omarchy host in headless mode: a terminal probe delivered/acked 70 frames and
answered one ping. A Finder-launched temporary native app invoked the same probe
with the actual GUI environment: PATH `/usr/bin:/bin:/usr/sbin:/sbin`, SSH agent
present, and an injected shell-only sentinel absent. It delivered/acked 67 frames,
answered one ping, then cancelled with state closed. Metadata is in
[evidence/finder-transport.json](evidence/finder-transport.json). No video contents
were logged or recorded by these probes; decode completion was synthetic.

The first short 5/10-second probes stopped before startup completed on this
network. Thirty-second probes are used for acceptance, while the implementation
still bounds startup at 20 seconds. A direct server preflight with stdin closed
correctly reported `read Hello: connection closed`.

Two further sequential connect/stop cycles delivered and acknowledged 63 and 54
frames respectively, with one pong each, and closed after cancellation. The
metadata is in [evidence/repeated-transport.json](evidence/repeated-transport.json).
The initial full check ran every local gate: 15 passed and only the stale
compatibility record failed. The record was refreshed against clean source
`315b474` with the new SSH gate; qualification awaits current-source CI/live
evidence. The implementation and regression tests total 46 passing Rust tests;
Swift tests, both Apple targets, universal bridge and Xcode app passed.
