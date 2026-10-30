# 08 — render-full-chroma-metal

Status: implemented on `feat/full-chroma-metal-rendering`; GPU live acceptance
passes, CPU live acceptance is blocked by an auxiliary keyframe contract
mismatch with the pinned server. [PR #9](https://github.com/Remi-B/gliff-mac/pull/9)
remains a draft. Independent review's P2 recovery finding is fixed and covered
by a regression. Fixture pairs (synthetic, live CPU, live GPU) decode and
recombine bit-exact with upstream's reference. Dependencies:
[07](../07-decode-and-display-h264/README.md).

Results: [implementation record](implementation-record.md).

## Outcome

Implement Gliff's full-colour Dual420 path: two ordinary H.264 decoders plus Metal
recombination. Native H.264 4:4:4 decoding is not assumed or advertised.

## Work

- [x] Create independent main/aux VideoToolbox sessions and retain both results
  under the same frame ID/configuration generation. Do not pair whichever buffers
  happen to complete last; handle asynchronous outputs and delayed/missing partners.
- [x] Implement upstream's precise main/aux chroma layout in Metal, referencing
  `gliff-proto/src/chroma.rs` and `color.rs` at the pinned SHA. Preserve plane strides,
  pixel formats, colour range/matrix and geometry; use CoreVideo texture mapping.
- [x] Build a CPU/reference fixture comparison for reconstruction and colour
  conversion, with exact checks where algorithms are integer-equivalent and defined
  tolerances where GPU arithmetic or lossy H.264 requires them.
- [x] Render completed pairs ~~and remote cursor~~ in a bounded Metal presentation path.
  Maintain Single420 support and safe mode changes during bandwidth adaptation.
  (The remote cursor belongs to [task 09](../09-implement-remote-input/README.md);
  it is satisfied by the integrated result, not by this branch.)
- [x] Publish `[Dual420, Single420]` capabilities only when supported by the current
  native pipeline. Keep Native444/H265/AV1 unadvertised unless separately implemented.
- [x] Define decode feedback for a complete pair and failure of either stream.
  Bound waiting pairs, request keyframes/reconfigure on failure, and avoid a silent
  half-colour frame or unbounded wait. Measure GPU/pixel-buffer lifetimes.

## Deliverables and acceptance

- Synthetic chroma patterns and coloured small text match the upstream reference;
  lossy decode comparisons use documented tolerances and independent expected data.
- A real unmodified server streams Dual420 with correct colour on the supported
  Mac matrix. Test both GPU and CPU/full-chroma server paths where available.
- Single420/Dual420 transitions, resolution changes and late callbacks never mix
  main/aux frames or generations; failure recovers or reports a clear error.
- Metal pipeline costs, native memory and pairing limits are recorded for task 12.
  Full-chroma support is a release gate, not inferred from a single-stream demo.

The native pipeline advertises Dual420 and Single420. `H264Decoder` completes
a Dual420 frame when both callbacks arrive, or fails it when either stream
fails or a partner expires. Metal reconstructs full chroma before aspect-fit
presentation. The implementation record distinguishes fixture checks, GPU
native live acceptance and the unresolved CPU server compatibility failure.
## Integration with the video encoder selector

The connection form lets the user pick Auto, CPU or GPU
(`ConnectionRequest.videoMode`, bridge `VideoMode`). It only changes the server
`--video` flag; it does not change what the client advertises. `LiveSession.chroma`
and the `videoMode:` argument of `ConnectionTarget.ssh` remain independent.
Use the Auto/GPU path to validate Dual420.

## Separate follow-up: CPU Dual420 compatibility

CPU Dual420 compatibility is not established by this task or by the selectable
encoder option. The pinned server can mark the main stream as a keyframe while
the auxiliary stream lacks SPS/PPS. The current client contract requires each
stream's keyframe parameter sets and correctly rejects that frame. Track any
compatibility change separately from encoder-performance work: first agree on
the protocol meaning and safe decoder recovery, then measure CPU cost and
optimize. Do not relax the contract or claim CPU Dual420 support as part of the
encoder selector.
