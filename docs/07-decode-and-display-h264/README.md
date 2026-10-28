# 07 — decode-and-display-h264

Status: planned. Dependencies: [05](../05-implement-ssh-session/README.md),
[06](../06-create-native-macos-app/README.md).

## Outcome

Display a live Single420 H.264 session using VideoToolbox and native presentation.
This is a view-only alpha milestone; it does not claim Gliff's full-chroma quality.

## Work

- [ ] Consume ordered configuration/frame envelopes. Parse verified Annex B NALs,
  obtain SPS/PPS from configuration or access units, convert samples to the required
  length-prefixed representation, and create CoreMedia format/sample buffers.
- [ ] Implement a serial-owned `VTDecompressionSession` pipeline with asynchronous
  output, frame ID/PTS/configuration identity, buffer lifetime and error feedback.
  Validate actual profiles and hardware/software behavior on supported Mac models.
- [ ] Present decoded CoreVideo buffers through a bounded native surface. Select
  one path: VideoToolbox decode plus presentation of decoded images, using an
  `AVSampleBufferDisplayLayer` host or Metal. Avoid accidentally decoding twice or
  treating a display layer alone as the future Dual420 recombination path.
- [ ] Apply upstream BT.709/limited-range reference behavior and actual format
  metadata; fit remote view geometry correctly through Retina backing scale,
  letterboxing and window resize. Carry geometry with each decoded frame.
- [ ] Report native decode results promptly to Rust for server frame feedback.
  Keep presentation metrics separate. Do not wait on the UI/main thread to read
  more transport bytes or acknowledge ordinary decode progress.
- [ ] Recreate decoder state on material format changes, ignore stale-generation
  output, flush/invalidate cleanly, request keyframes after decode failure, and keep
  the last valid still image. Frame-rate-only changes must not restart decoding.
- [ ] Bound buffers/queues; prefer dropping decoded display frames over compressed
  predictive frames. If compressed backlog is abandoned, explicitly recover at a
  keyframe. Expose reduced chroma and decode failures in diagnostics.

## Deliverables and acceptance

- Baseline server and task-02 fixtures show correct live Single420 video, sharp
  geometry and expected colour without a Linux video dependency.
- Tests exercise SPS/PPS changes, truncated samples, delayed output, static desktop,
  resize, decoder failure/keyframe recovery and disconnect with work in flight.
- Queue growth remains bounded under a slow display; server pacing continues and
  teardown releases native buffers and callbacks.
- Record Apple Silicon and Intel build/runtime results separately; hardware
  availability limitations remain visible in the compatibility matrix.
