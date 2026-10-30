# Video quality investigation and optimization

Status: planned; part of task 12. Measure causes before selecting fixes.

## Observations

On 2026-10-31, the user tested the macOS connection selector against Omarchy:
CPU mode appeared sharp; GPU mode initially showed degraded quality and became
sharp after the stream stabilized. These are subjective observations, not a
measured comparison or proof that every CPU/Dual420 path works. Separate live
tests reproduced a CPU Dual420 auxiliary keyframe contract failure; see the
[task 08 record](../08-render-full-chroma-metal/implementation-record.md).

Earlier synthetic probes suggested both encoding at low bitrate and fractional
bilinear scaling can reduce text sharpness. Their synthetic pattern, encoder
settings and modeled scaling do not establish the cause of the user's live
experience. Distinguish Dual420 reconstructed 4:4:4 from Single420 and from
lossless video; the negotiated mode can change during adaptation.

## Investigation and acceptance

- [ ] Reproduce CPU and GPU behavior on a controlled matrix: encoder and driver,
  source/output resolution, mirror/headless, scale, network conditions, chroma,
  frame rate, bitrate, keyframes and time since connection. Record actual mode
  and encoder; a GPU preference can fall back to CPU.
- [ ] Compare identical synthetic text, colored detail and motion at the source,
  after encoding/reference decoding, after native VideoToolbox/Metal conversion,
  and after presentation at 1:1 and fractional scales. Measure quality and
  stabilization time, including initially static content and motion recovery.
- [ ] Investigate startup bitrate, rate adaptation, encoder keyframes and
  refinement, plus filtering and color handling. Fix the demonstrated causes and
  add reproducible regression checks; do not infer a single cause in advance.
- [ ] Compare with the original upstream Gliff client and pinned server using
  equivalent content, resolutions, output scaling and network conditions. If
  useful, evaluate an Omarchy VM on the Mac; record VM/GPU limitations and do
  not assume it matches native hardware. Compare against a native Linux run
  when virtual GPU acceleration or encoder behavior differs.
- [ ] Resolve CPU Dual420 keyframe compatibility separately before claiming
  support, then benchmark and optimize CPU performance. Preserve the strict
  contract until a safe upstream-compatible behavior is established.
- [ ] Record exact revisions, hardware, drivers, commands, metrics, failures and
  unavailable cases. Define acceptance thresholds from the measurements and
  verify no quality fix regresses latency, recovery or resource bounds.

Use synthetic content on a temporary virtual output for automated captures;
never capture the user's physical desktop as test evidence.
