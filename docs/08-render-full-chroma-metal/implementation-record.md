# Task 08 implementation record

Updated: 2026-10-30. Branch `feat/full-chroma-metal-rendering`, based on merged
task 07 (`9d33b87103cd47551450096fd638ebfd43d11614`). The implementation has
independent review; CPU live acceptance blocks completion and qualification.
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

## Validation

On Apple M4 Pro, macOS 27.0.1, Xcode 27.1, the hosted app suite passed 75 tests
in 15 suites (81.505 s) on product source `3e4c146`. The tests cover exact reconstruction with padded
strides, synthetic coloured small text, upstream hashes for synthetic and live
CPU/GPU Dual420 fixtures, source-picture PSNR with defined lossy tolerances,
mode/generation changes, auxiliary corruption, recovery, pairing deadlines,
out-of-order callbacks and redraw reuse. `ChromaReference.swift` ports upstream's
CPU algorithms; committed fixture hashes provide an independent expected result.
Four discovered races have regression coverage: an old generation's failed job
must not invalidate new references, epoch validation and picture installation
must be atomic, and overflow must discard the incoming sample before submitting
it against lost references. Independent review found a fourth case: an older
timeout after a successful IDR in the same generation must not invalidate that
new IDR's reference chain. Its regression failed with three assertions before
the fix, then passed with all 30 affected native tests. No review findings were
rejected. Renderer saturation/recovery/reset also has regression coverage.

Xcode 16.4 CI found Swift 6.1 rejected a raw CoreVideo buffer capture in the
pairing stress test that the local compiler accepted. An immutable sendable test
wrapper fixes the ownership declaration; the affected suite passes locally.
The pinned-toolchain CI rerun and compatibility refresh are recorded on the PR.

Diagnostic costs from 30 Dual420 reconstructions plus 30 Single420 conversions
at each size (command-buffer GPU timestamps, including readback; not isolated
kernel latency or a performance guarantee):

| Size | GPU mean / max | Pair IOSurfaces | RGB texture |
| --- | --- | --- | --- |
| 1920×1080 | 293 / 760 µs | 6,644,672 bytes | 8,294,400 bytes |
| 3840×2160 | 1,592 / 4,110 µs | 24,900,992 bytes | 33,177,600 bytes |

The pending-pair cap bounds retained incomplete pictures separately from the
latest display picture and GPU-owned resources. Full process-memory and sustained
presentation measurements remain task 12 work; these allocation observations do
not establish a total native-memory ceiling.

## Native live results and CPU acceptance blocker

Clean-source headless runs used the unmodified pinned server on Omarchy,
Hyprland 0.56.2. The GPU recorder passed with four frames and resize. The real
GPU SSH → VideoToolbox → Metal suite passed with 58 complete pairs, 58 ACKs,
1920×1080 → 1280×800 resize, exact GPU/CPU pixel comparison and cancellation.
These results test product source `3e4c146`; the subsequent compiler fix changes
only test ownership declarations, not product code.

CPU Dual420 is **not accepted**. Earlier recordings passed, but later clean
recordings failed at frame 1 or 3 with `keyframe … lacks in-band SPS/PPS before
its IDR in the aux stream`. Two native SSH runs decoded three pairs with three
ACKs and resize, then ended with the same contract error. They failed the
expected clean-cancellation assertion. These are failed acceptance runs, not
successful end-to-end CPU results. Upstream `gliff-sw::encode_bgra` derives the
header's keyframe flag from the main encoder and does not use the auxiliary
encoder's keyframe result; this is consistent with, but does not alone establish
the cause of, the observed mismatch. The audited strict contract and vendor
source remain unchanged pending a compatibility-policy decision.

Fresh recording replay verified GPU and CPU output against the reference for
delivered frames, but latest-wins generation changes dropped some recorded
frames (3/4 GPU and 2/4 CPU). This partial replay is not complete live acceptance.

After the live tests, no gliff-server process or temporary headless output
remained; only `eDP-1` was present. The two temporary task-08 cache wrappers were
removed and the host was released to task 09. No physical output was captured.

Intel runtime, deployment-minimum macOS, a fresh Finder-launched Dual420 session
and integrated task-09 input/cursor acceptance remain unverified. Full-chroma
release qualification is blocked; the PR stays a draft. Compatibility records
must not turn the GPU pass into a CPU pass.

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
