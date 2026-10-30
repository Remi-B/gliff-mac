# Task 08 implementation record

Updated: 2026-10-30. Branch `feat/full-chroma-metal-rendering`, based on merged
task 07 (`9d33b87103cd47551450096fd638ebfd43d11614`). Implementation is under
validation; independent review and final compatibility qualification are pending.
Upstream is unchanged at `58c742452ded3f10a2ce61f60eb4845f18205e29` (0.4.1).

## Video pipeline

`H264Decoder` owns two independent VideoToolbox sessions for Dual420, or one
for Single420. Every submitted frame owns a `FrameJob`; callbacks capture that
job rather than pairing pictures by completion order. A complete pair reports
`decoded` once; either stream's failure reports `failed` once and requests a
keyframe through the existing bridge. Pictures never render with only half of
their required chroma. Pending jobs are capped at 64 (the ordinary bridge budget
is four); missing callbacks expire after three seconds. Predicted pictures are
discarded after failure until an IDR pair restores both reference chains.

`VideoRenderer` maps the IOSurface-backed main/aux NV12 planes through CoreVideo
and reconstructs upstream's AVC444 layout in a Metal compute kernel. Main UV
supplies even-row/even-column chroma, auxiliary UV supplies even-row/odd-column
chroma, and auxiliary Y's two halves supply U and V on odd rows. The conversion
uses upstream's fixed-point coefficients. CoreVideo mappings and both buffers
are retained until the command buffer completes. Aspect-fit presentation and the
latest-picture handoff remain in place. Presentation admits at most three GPU
command buffers without waiting for a slot; saturation or a missing drawable
returns for retry with the latest picture. Converted textures enter the redraw
cache only after successful GPU completion; reset invalidates late cache updates.

The main stream's format description supplies its signalled colour matrix.
Without a VUI colour description, BT.709 follows upstream's encoder conversion.
This fixes a discovered GPU fixture mismatch: VideoToolbox guessed BT.601 for
the untagged 640×480 VA-API stream. A regression covers this distinction.

## Interfaces and scope

- `FrameGeometry`, existing `VideoDisplay` methods and `RemoteSurfaceView` are unchanged.
  The additive `VideoDisplay.postDeferred` helper installs a picture while the
  decoder epoch is locked, deferring the observer until after unlocking.
  `DecodedFrame` adds optional `aux` and `isFullChroma`; diagnostics add pairing,
  completion-time and native-buffer-byte counters.
- `RemoteSession.swift` adds `LiveSession.chroma = [.dual420, .single420]`, used
  by the factory and fixture replay. The Rust SSH target now honours configured
  chroma instead of overriding it with Single420. Native444/H265/AV1 remain absent.
- Cursor implementation belongs to task 09. These branches require integrated
  video/input/cursor checks after task 08 merges first.

## Validation so far

On Apple M4 Pro, macOS 27.0.1, Xcode 27.1, the hosted app suite passed 69 tests
in 14 suites (80.277 s). The new tests cover exact reconstruction with padded
strides, synthetic coloured small text, upstream hashes for synthetic and live
CPU/GPU Dual420 fixtures, source-picture PSNR with defined lossy tolerances,
mode/generation changes, auxiliary corruption, recovery, pairing deadlines,
out-of-order callbacks and redraw reuse. `ChromaReference.swift` ports upstream's
CPU algorithms; committed fixture hashes provide an independent expected result.
Three discovered races have regression coverage: an old generation's failed job
must not invalidate new references, epoch validation and picture installation
must be atomic, and overflow must discard the incoming sample before submitting
it against lost references. The affected native suites passed twice (28 tests
in the final race run). Renderer saturation/recovery/reset tests and the opt-in
native SSH suite were added afterwards; final full gates remain pending.

Diagnostic costs from 30 Dual420 reconstructions plus 30 Single420 conversions
at each size (command-buffer GPU timestamps, including readback; not isolated
kernel latency or a performance guarantee):

| Size | GPU mean / max | Pair IOSurfaces | RGB texture |
| --- | --- | --- | --- |
| 1920×1080 | 259 / 282 µs | 6,644,672 bytes | 8,294,400 bytes |
| 3840×2160 | 1,419 / 17,923 µs | 24,900,992 bytes | 33,177,600 bytes |

The pending-pair cap bounds retained incomplete pictures separately from the
latest display picture and GPU-owned resources. Full process-memory and sustained
presentation measurements remain task 12 work; these allocation observations do
not establish a total native-memory ceiling.

## Outstanding evidence

Fresh headless CPU/GPU server recordings and native replay, final full gates,
compatibility record refresh and independent review are in progress. Intel and
the deployment-minimum macOS runtime are not tested on this Apple Silicon host.
A fresh Finder-launched Dual420 session and integrated task-09 cursor/input
acceptance have not been demonstrated by the recorded-fixture suite.

Terra completed the decoder race fixes, bounded presentation and the opt-in
native SSH test after taking over implementation. Independent review and fresh
clean-source evidence remain outstanding.

## Opt-in native SSH acceptance

`NativeSSHVideoTests` uses the real SSH bridge, VideoToolbox and Metal. Set a
JSON array of complete `ConnectionRequest` records, one per headless server
wrapper; `port` is a string and empty optional fields use SSH defaults. Server
wrappers select the CPU or GPU full-chroma path. For example:

```sh
TEST_RUNNER_GLIFF_LIVE_TARGETS='[{"host":"HOST","user":"USER","port":"22","identityFile":"/absolute/key","serverPath":"/absolute/cpu-wrapper","headless":true},{"host":"HOST","user":"USER","port":"22","identityFile":"/absolute/key","serverPath":"/absolute/gpu-wrapper","headless":true}]' \
  scripts/test-app.sh -only-testing:GliffMacTests/NativeSSHVideoTests
```

Use the suite selector shown: the previously documented single-method selector
without parentheses selected zero tests. The test requires Dual420 before and
after a headless resize, compares Metal pixels with the CPU reference, checks
acknowledgement and failure counters, and cancels each session. Reserve the host
before running it; adding this opt-in test does not constitute live evidence.
