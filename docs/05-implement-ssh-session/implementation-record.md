# Task 05 implementation record

Updated: 2026-10-30. Branch `feat/ssh-session`. Status: in review.
Dependencies 03 and 04 are merged. Upstream remains the unmodified pinned
`58c742452ded3f10a2ce61f60eb4845f18205e29` (`gliff-server 0.4.1`).

## Delivered behavior

The public Rust/Swift session API now runs absolute `/usr/bin/ssh` with piped
stdio, batch key/agent authentication and strict ordinary known-host verification.
Host/user/port, optional absolute identity file, quoted remote executable and
headless mode are structured fields; there is no raw command or flags API.
Normal config aliases, identities and ProxyJump settings are included without
editing user SSH files. Protocol framing and serialization remain upstream-owned.

A private session-scoped `-F` config applies mandatory batch authentication,
strict verification, 10-second connection attempts, no agent/X11/port forwarding,
no multiplexing/local commands and foreground stdio before including ordinary
user/system configuration. OpenSSH propagates this file to generated ProxyJump
commands. It is removed after the process group and stderr worker stop.

The adapter owns a dedicated process group, sends TERM then KILL after at most
200 ms, reaps SSH and terminates surviving proxy descendants before `onEnded`.
A drop guard covers task unwinding. Stderr is continuously drained with 16 KiB
retained; only fixed actionable/redacted guidance reaches the bridge. An
inherited stderr descriptor has a one-second abort-and-join deadline. Normal
logged EOF uses the child's exit status; diagnostics never mask typed fatal
protocol/version failures.

`state()` exposes connecting, handshaking, streaming, stopping, closed and failed.
Startup stays bounded at 20 seconds through the first StreamConfig, including
blocked Hello writes and HelloAck followed by silent video setup. A frame
unreported by the native decoder for 15 seconds fails the session (100 ms
watchdog resolution). Normal failed/discarded reports retain ordered ack and
keyframe recovery. The existing ordered callbacks, byte/count budgets and
back-pressure driver are shared with replay. Live SSH advertises only
H.264/Single420; dual-stream replay remains for fixtures until task 08.

## Acceptance evidence

Final clean source `497a82b` on macOS 27.0.1 arm64 / Xcode 27.1 / Rust 1.90.0:

| Check | Evidence |
| --- | --- |
| Full entrypoint | `scripts/check.sh`: 16 passed, 0 failed, 8 unavailable; live-server evidence collected separately, upstream Linux runs in CI, six gates belong to later tasks |
| Rust | 51 app tests plus 3 fixture-tool tests; Clippy with warnings denied; rustfmt |
| Native builds | Both Apple Rust targets, dependency/portability audit, matching generated bindings, universal XCFramework and Xcode app |
| Swift | Nine Swift tests passed on arm64; x86_64 package/tests compiled |
| Protocol faults | Existing replay/mock tests cover malformed/unknown messages, incompatible versions, truncated EOF, payload association, cancellation, ordered feedback and recovery |
| Startup/decode deadlines | Blocked Hello, silent peer, HelloAck without config, and stalled native completion regressions |
| Process lifecycle | Stderr flood and repeated cleanup; observed PID tests for a TERM-resistant child and a proxy descendant retaining stderr; stderr worker abort/join test. Process regressions passed three consecutive runs |
| Jump security | Real `ssh -G` evaluation for destination and jump aliases preserves user/port/identity while overriding permissive auth, verification and forwarding; generated ProxyCommand retains the policy file |
| Public-facade live transport | Headless sessions delivered/acked 70 frames, then sequential cycles of 63 and 54, with one pong each and clean cancellation |
| Finder environment | Actual Finder launch through a temporary native app: PATH `/usr/bin:/bin:/usr/sbin:/sbin`, GUI agent present, shell sentinel absent. After both reviews: 39 delivered frames, 39 acks, one pong, state closed |
| Live reference decode | Unmodified pinned CPU server; four frames recorded/decoded with the reference decoder; client Resize changed 1920×1080 to 1280×800 |

The Finder metadata is [finder-transport.json](evidence/finder-transport.json);
initial sequential-cycle metadata is [repeated-transport.json](evidence/repeated-transport.json).
The facade probe reports synthetic native decode completion, so its counters
prove transport pacing, not VideoToolbox decoding. It logs no video contents.
The separate reference-decoder check uses headless default-background frames.
No SSH/server child or private policy file remained after the completed probes.
The first short 5/10-second probes ended before setup completed on this network;
acceptance used 30-second probes while preserving the 20-second startup bound.

## Independent review

Sol reported four P2 findings, all verified and fixed by the parent:

1. Destination SSH options did not propagate to ProxyJump: private per-session
   policy now applies to every generated hop; effective-config regressions pass.
2. Killing only the SSH PID could leave proxies alive: process-group termination
   and bounded escalation now precede completion; observed PID regressions pass.
3. ClearAllForwardings left agent/X11 forwarding enabled: explicit prohibitions
   apply to the destination and generated hops; argv/config regressions pass.
4. Cleanup tests only checked return values: new PID and worker-drop witnesses
   establish process disappearance and worker joining before completion.

Integration also fixed logged clean EOF, stderr masking typed incompatibility,
executable-permission classification, and startup timeout after HelloAck. CI,
qualification and the full evidence/review report are published on the PR.
The current-pin record is qualified from clean local/live source `497a82b` and
the successful CI push run on `4dcf20a`: all 18 required gates passed across
local macOS 27/Xcode 27.1, CI macOS 15/Xcode 16.4, Ubuntu and Arch upstream.
Only documentation and compatibility metadata changed after the tested code.

## Limits

Intel runtime, real multi-host ProxyJump/agent combinations, and native
VideoToolbox completion remain unverified. Host-key/auth guidance has deterministic
coverage; real known_hosts was not modified for fault injection. No password or
private-key store is added. Custom user-authored ProxyCommand programs remain
trusted configuration; a helper that deliberately creates its own session/daemon
escapes the process-group lifecycle contract. The app exposes no such raw input.

## Additional Opus review

Opus independently confirmed the four Sol fixes and found one further P2:
user-configured RemoteCommand conflicts with Gliff's server command. The private
policy now forces RemoteCommand none and Tunnel no for destination and jump
aliases; the effective-config regression includes conflicting user settings.
The small P3 findings were also addressed: avoid signalling an already absent
process group, preserve startup timeout reasons despite stderr warnings, use
neutral diagnostics after an established session exits, align the bridge
contract with actual states/validation, and reject literal remote `~/...` paths
with setup guidance. Timeout, live-exit and path-validation regressions cover
the behavior changes; the existing process/PID tests cover teardown.

## CI scope validation

The additional CI change has 16 passing tests using real temporary git histories
and passes actionlint v1.7.7. It conservatively reuses successful ancestral push
validation only when the tested tree differs under `docs/` alone. API failures,
unvalidated code, new base-branch code and manual/reusable runs use full checks.
Full push/PR checks passed on `4dcf20a` and the qualification-only commit
`771a84a`; all 18 required compatibility gates are qualified. This documentation
update changes only `docs/` and is the live acceptance case for skipping the
expensive jobs while retaining the scope check.
