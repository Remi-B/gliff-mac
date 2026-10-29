# 12 — validate-performance-and-end-to-end

Status: planned. Dependencies:
[03](../03-automate-upstream-sync-and-compatibility/README.md),
[08](../08-render-full-chroma-metal/README.md),
[09](../09-implement-remote-input/README.md),
[10](../10-implement-displays-and-reconnection/README.md),
[11](../11-implement-shared-clipboard/README.md).

## Outcome

Produce reproducible evidence that the native client works with real upstream
servers and stays responsive under load. Convert observations into explicit
release budgets rather than inventing unmeasured latency/FPS claims.

## Work

- [ ] Assemble a matrix of supported macOS versions, Apple Silicon/Intel hardware,
  initial release/current pin/candidate server, CPU/GPU encoding, Single420/Dual420,
  mirror/headless, display scale, and supported keyboard layouts. Record skips.
- [ ] Provide fixture/replay checks runnable without a compositor, native decoder/
  Metal integration checks on Macs, and a separate live Linux/Hyprland acceptance
  script/manual recipe. Hardware-dependent cases must identify their host/driver.
- [ ] Complete the dedicated [SSH multi-hop implementation and live validation
  task](ssh-multi-hop.md): real one-/multi-bastion routes, per-hop security and
  authentication, native video, failure/cleanup tests and required implementation
  corrections. Record unavailable routes and keep this subtask open until verified.
- [ ] Measure first-frame time, decode/presentation latency, input response, FPS,
  compressed/FFI bandwidth, frame queue/byte counts, CPU/GPU use and memory. Document
  clock methodology; do not subtract unsynchronized server/client clocks as latency.
- [ ] Baseline 1080p and high-resolution/Retina workloads, static text, rapid scroll,
  colour patterns and long sessions over LAN and shaped slow/high-latency links.
  Set reviewed p50/p95 and memory/queue budgets from those baselines before release.
- [ ] Inject delayed main/aux output, corrupt/truncated input, config churn, link
  drops, disk pressure, simultaneous clipboard load and cancellation. Validate
  bounded memory and recovery without arbitrary encoded-frame loss.
- [ ] Compare full-chroma reconstruction and scaling against independent upstream
  reference fixtures; measure bridge copies before adding unsafe optimizations.
- [ ] Exercise one real upstream change when available and a full pin rollback,
  connecting task 03's automation to all implemented acceptance gates.

## Deliverables and acceptance

- A dated compatibility/performance report with exact app/server/toolchain/lockfile
  provenance and reproducible commands/fixtures. All promised platforms/features
  have runtime evidence; missing hardware is a release blocker for those claims.
- The reviewed budgets are met without progressive memory growth, orphaned tasks,
  stuck keys, colour corruption or clipboard leakage across ownership changes.
- Every implemented feature survives repeated connect/disconnect, sleep/wake,
  resize and failure recovery. Local release controls remain usable under load.
- SSH multi-hop acceptance includes real routes and regression-covered corrections
  described in [the dedicated subtask](ssh-multi-hop.md), beyond task 05's mocks.
- CI enforces deterministic regressions, and the documented hardware suite is run
  for release candidates and upstream changes affecting native interoperability.
