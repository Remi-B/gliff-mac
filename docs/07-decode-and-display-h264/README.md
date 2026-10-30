# 07 — decode-and-display-h264

Status: merged (#8); fixture decode is bit-exact with upstream's reference, and
Finder-launched live sessions (headless and mirrored) were decoded and
acknowledged natively.
Dependencies: [05](../05-implement-ssh-session/README.md),
[06](../06-create-native-macos-app/README.md).

Results: [implementation record](implementation-record.md),
[live evidence](evidence/finder-live-decode.json).

## Outcome

Display a live Single420 H.264 session using VideoToolbox and native presentation.
This is a view-only alpha milestone; it does not claim Gliff's full-chroma quality.

## Work

- [x] Consume ordered configuration/frame envelopes. Parse verified Annex B NALs,
  obtain SPS/PPS from configuration or access units, convert samples to the required
  length-prefixed representation, and create CoreMedia format/sample buffers.
- [x] Implement a serial-owned `VTDecompressionSession` pipeline with asynchronous
  output, frame ID/PTS/configuration identity, buffer lifetime and error feedback.
  Validate actual profiles and hardware/software behavior on supported Mac models.
- [x] Present decoded CoreVideo buffers through a bounded native surface. Select
  one path: VideoToolbox decode plus presentation of decoded images, using an
  `AVSampleBufferDisplayLayer` host or Metal. Avoid accidentally decoding twice or
  treating a display layer alone as the future Dual420 recombination path.
- [x] Apply upstream BT.709/limited-range reference behavior and actual format
  metadata; fit remote view geometry correctly through Retina backing scale,
  letterboxing and window resize. Carry geometry with each decoded frame.
- [x] Report native decode results promptly to Rust for server frame feedback.
  Keep presentation metrics separate. Do not wait on the UI/main thread to read
  more transport bytes or acknowledge ordinary decode progress.
- [x] Replace task 05's synthetic decode-completion probe with an end-to-end native
  path: real SSH frames enter VideoToolbox, actual asynchronous output callbacks
  report decode results to Rust, and decoded buffers appear in the app surface.
- [x] Recreate decoder state on material format changes, ignore stale-generation
  output, flush/invalidate cleanly, request keyframes after decode failure, and keep
  the last valid still image. Frame-rate-only changes must not restart decoding.
- [x] Bound buffers/queues; prefer dropping decoded display frames over compressed
  predictive frames. If compressed backlog is abandoned, explicitly recover at a
  keyframe. Expose reduced chroma and decode failures in diagnostics.

## Deliverables and acceptance

- Baseline server and task-02 fixtures show correct live Single420 video, sharp
  geometry and expected colour without a Linux video dependency.
- A Finder-launched app displays a real headless server stream through VideoToolbox
  and acknowledges frames from actual native completion. Simulated acknowledgements
  or successful reference-decoder replay alone do not satisfy this acceptance.
- Tests exercise SPS/PPS changes, truncated samples, delayed output, static desktop,
  resize, decoder failure/keyframe recovery and disconnect with work in flight.
- Queue growth remains bounded under a slow display; server pacing continues and
  teardown releases native buffers and callbacks.
- Record Apple Silicon and Intel build/runtime results separately; hardware
  availability limitations remain visible in the compatibility matrix.

Intel runtime remains unverified on this Apple silicon Mac; see the record's limits.

From task 06: replace `LiveSession`'s placeholder video closure
(`macos/GliffMac/Model/RemoteSession.swift`), which reports frames `decoded`
for pacing only. Host the layer in `RemoteSurface.SurfaceView`, and set
`StreamInfo.displaysVideo` so the surface stops showing its placeholder.
