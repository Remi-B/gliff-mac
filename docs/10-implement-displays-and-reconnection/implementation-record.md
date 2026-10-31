# Task 10 implementation record

Updated 2026-10-31. Branch `feat/displays-and-reconnection`, based on merged task 09
`b1c7fd9`. Upstream stays unmodified at `58c742452ded3f10a2ce61f60eb4845f18205e29`
(Gliff 0.4.1). No wire extension is needed: every behaviour uses existing server
options (`--headless`, `--output`) and messages (`Resize`, client `Ping`).

## Display modes

- **Virtual display** (`--headless`, the default): the server creates its own output,
  starting at 1920×1080 at scale 1, and resizes it to every `Resize`.
- **Mirror**: `--output NAME`, or the server's focused output when the name is empty.
  The form shows an "Output to mirror" field only in mirror mode. The bridge adds
  `ConnectionTarget.Ssh.output` and validates it like the form: ASCII letters, digits,
  `.`, `_`, `-`, at most 64 characters, never with `headless` (the server rejects
  `--output` with `--headless`). It is quoted into the remote command.
- The mode and output are saved with the recent host (`ConnectionRequest.output`;
  older entries decode as the focused output) and shown in the recent list.
- The server lists only the served output in `HelloAck`, so the client cannot offer a
  list of outputs; the name is typed (`hyprctl monitors`).

## Resize

The surface reports its size in backing pixels and its scale on every layout (window
resize, full screen, Retina/non-Retina moves, which change the scale). The controller
waits for the size to hold for 200 ms, as upstream's client does, then sends
`Resize { width, height, scale }` with even sizes. It is sent again only when the size
or scale changes, once per session (a reconnected session gets the current size after
its first configuration), never below the server's 320×240 minimum, and retried after
another 200 ms if the input queue is full. A virtual display is resized at that scale;
a mirrored output is scaled down to fit the window. The picture and pointer mapping
follow the decoded frames, so a new configuration never misaligns input (task 09).
No new `HelloAck` follows a resize, so the cursor's output scale (task 09) is
updated from each configuration of a virtual display: the configuration's effective
scale when the stream is not downscaled, else the requested scale. A mirrored output
keeps the scale from `HelloAck`.
Scale-only configurations (`rebuild = false`) keep the decoder, as fps-only ones
already did (task 07 test `aPaceOnlyConfigurationKeepsTheDecoder`).

## Liveness

The server pings once at startup and sends frames only on damage, so silence is
normal. Once streaming, `gliff-client-core` sends `Ping` after 5 seconds without a
server message (at most every 5 seconds) and ends the session with a timeout after
15 seconds of silence while it is willing to read. Time the driver spends not reading
because the in-flight budget is full is not counted: the existing 15-second decode
watchdog covers it. Every byte read counts as hearing from the server, not only complete messages, so a
large keyframe arriving slowly over a weak link is not mistaken for silence.
The check runs in the driver's watchdog, outside the writer, so a
peer that stopped reading cannot block it. Live, a stopped server and a stopped sshd
(a dropped network) were both detected in about 15.7 seconds; SSH keepalive alone
(10 s × 2) would take longer and does not see a stopped server.

## Reconnection

Errors are classified in the bridge:

| End | Automatic retry |
| --- | --- |
| `Transport`: timeouts, unreachable host, link lost, silence, SSH ended unexpectedly | Yes |
| Server closed the stream after streaming | Yes |
| `Setup` (new): host key, key authentication, server missing or not executable | No: user action needed; Try Again stays available |
| `Contract`, `VersionMismatch`, `Incompatible`, `InvalidOptions`, `Unsupported` | No: fatal, Edit Connection only |
| `Protocol` | No |
| The user's disconnect, window close or quit | No |

Only a link that streamed, or a series already running, is retried: a first attempt's
failure goes to the user. A series waits 1, 2, 4, 8 and 16 seconds before its five
attempts, then shows the last error with "Gliff tried 5 times". A session that streams
for 30 seconds ends the series; a shorter one continues it, so a server failing right
after each start cannot loop. While waiting, the window shows the reason and attempt,
with Try Now and Cancel; Disconnect, Cancel, window close and quit cancel the wait at
once. The toolbar's Reconnect starts a fresh attempt.

Every attempt is a new `GliffSession` (SSH process, handshake, capability evaluation),
`SessionID`, `H264Decoder`/`VideoDisplay` and `InputForwarder`. Input is released on the
old session when it ends, nothing is queued across sessions, and callbacks from old
sessions are dropped by `SessionID` (controller) and by each decoder's own session
reference (reports, pictures). `lateHalvesAcrossAReconnectStayWithTheOldDecoder` feeds
late Dual420 halves to an invalidated decoder while a new one decodes the same
generation and frame numbers. A status bar label counts automatic reconnections.

## Sleep, wake, network and app lifecycle

`SystemEvents` forwards `NSWorkspace` sleep/wake and `NWPathMonitor` to every window's
controller. Sleep ends the active session at once (so SSH says goodbye and the server
removes its virtual display) and waits for wake, which starts a new session; no timer
or network event starts one while asleep. A network path that becomes available again
cuts a backoff wait short; a lost path is left to the session's own detection.
Background/foreground needs nothing new: losing the key window already releases input
(task 09), and a session keeps streaming in the background. Window close and quit are
unchanged (task 06): cancel, then the registry waits for the bridge to reap SSH.
Clipboard offers do not exist yet; task 11 re-establishes them under its ownership
policy.

## Statistics

`SessionStats` adds `pings_sent`, current `in_flight_frames` (queue pressure) and the
last and maximum decode delay (admission to report). The session summary in the `video`
log adds pings, peak in flight and maximum decode delay; the `session` log shows phases
with attempt numbers and fixed reasons. Neither contains hosts, users, paths or pictures.
Multi-session UI polish is left for later; lifecycle state is per window and per session.

## Validation

Local platform: macOS 27.0.1 arm64, Xcode 27.1, Rust 1.90.0. Live host: Omarchy x86_64,
Hyprland 0.56, unmodified server at the pin. Evidence:
[`evidence/live-displays.json`](evidence/live-displays.json).

| Criterion | Evidence |
| --- | --- |
| Liveness | `crates/gliff-client-core/tests/liveness.rs`: silent server pinged then timed out at 15 s; answering server stays up 120 s; no ping before the first configuration; a 32-second keyframe is not silence |
| Error classes, mirror argument | `ssh::tests`: setup vs link diagnostics, `--output` quoting/validation, refused with `--headless` |
| Reconnect policy | `ReconnectionTests`: backoff timing, limit and last error, setup/fatal stop, first attempt not retried, server close retried, quick-failure series, disconnect/close/attempt cancellation, network return, Try Now |
| Sleep/wake | `ReconnectionTests`: sleep cancels and releases held keys, nothing starts while asleep, wake starts a clean session, late end ignored |
| Resize | `ReconnectionTests`: 200 ms settle, even backing pixels, scale-only resend, minimum size, after streaming only, resent to a reconnected session, retry on a full queue |
| Requests and persistence | `ConnectionRequestTests`: output validation equals the bridge's, old entries, stored keys |
| Late output across generations | `Dual420DecoderTests.lateHalvesAcrossAReconnectStayWithTheOldDecoder`, existing generation tests |
| Live resize | 5 `Resize` requests (Retina, non-Retina, scale only) each answered by a matching configuration in 65–136 ms; scale only as `rebuild = false` |
| Live mirror | temporary headless output mirrored by name; `HelloAck` names it; a half-size window scales the stream to 960×540 |
| Live failures | server SIGKILL: link failure in 0.7 s; server SIGSTOP and sshd SIGSTOP: "stopped responding" in ~15.7 s; all retryable |
| Live cycles | 10 connect/stream/cancel cycles with queued keys: each cancelled in 11–14 ms; no server, output or local ssh left |
| GUI app | Debug app, auto-connected: virtual display = window surface (2418×1520 at 2); after a server kill and a server stall it reconnected by itself and re-applied the size 0.46 s after the first configuration; quitting removed the server and output |

### Findings

- A server killed with SIGKILL cannot remove its headless output: Hyprland keeps
  `gliff-<pid>` until removed by hand. Normal teardown, a stalled server once resumed
  and sshd loss all clean up. This is an upstream server limitation. After merge, a
  monitor tool disabling the output mid-session left one too;
  [task 14](../14-clean-up-orphan-monitors/README.md) removes orphans from the client.
- On the test network the host's global IPv6 address does not answer SSH. With the
  policy's `ConnectTimeout 10`, OpenSSH spends the whole 10 seconds on it before IPv4,
  so every connection (and reconnection) to that host takes about 10 seconds longer;
  plain `ssh` without a timeout falls back at once. `AddressFamily inet` in the user's
  SSH config avoids it. The client keeps its policy.
- `olderExpiryDoesNotInvalidateANewerIDRInTheSameGeneration` failed once under the full
  check: its fixture helper replays through the real bridge, which by design discards
  the last generation-1 frames when it has already read generation 2's configuration.
  The helper now keeps one frame in flight, so the driver cannot read the next
  configuration before a frame is delivered and the collected stream is complete.

### Independent review

GPT-6.1 Sol (high effort, read-only) reviewed the PR. Both findings were confirmed and
fixed with a regression test each:

| Finding | Fix |
| --- | --- |
| Medium: after a virtual display moves from scale 1 to 2, the cursor kept HelloAck's scale, doubling its size and offsetting its released position | Output scale follows each virtual-display configuration (`theCursorFollowsTheVirtualDisplaysNewScale`) |
| Medium: liveness was refreshed only by complete messages, so a keyframe arriving for more than 15 s on a slow link would end the session | Every byte read refreshes liveness (`a_large_frame_arriving_slowly_is_not_silence`, which fails without the fix) |

No other significant findings in reconnect limits and cancellation, stale-session
isolation, input release, resize debounce, error classification, output validation and
quoting, persistence, `SystemEvents` threading or the layout callback.

### Not verified here

- Interactive window resizing, full screen and moving between Retina and non-Retina
  displays in the GUI (no UI scripting permission): the same surface report and
  controller path is covered by tests and the GUI's initial and reconnect sizes.
  After review, the user resized the window by hand on 2026-10-31 and accepted it.
- A real sleep/wake cycle of this Mac; covered by controller tests only.
- Intel macOS runtime (compile-only, as before).
