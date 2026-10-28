# Task 02 implementation record

Updated: 2026-10-28. Branch `feat/audit-upstream-protocol`. Status: audit, contract and
replay harness complete; live server captures pending a Linux/Hyprland host.

## Delivered

- [Protocol and behaviour inventory](protocol-inventory.md): reuse/adapt/native
  boundary with source paths and symbols at `58c7424`, framing, limits, compatibility
  rules, handshake, video, pacing, input, cursor, display, clipboard, licences.
- [Session and video contract](session-video-contract.md): provisional records for task
  04 and rules for tasks 05/07, with a sequence diagram.
- [Portability audit](portability-audit.md) and `scripts/audit-portability.sh`.
- `crates/gliff-client-core`: `annexb` (NAL inspection), `video` (`StreamTracker`,
  `VideoConfig`, `EncodedFrame`, `FrameDisposition`, `DecoderSupport`) and `events`
  (`ServerReader`, `ServerEvent`, `SessionError`) over upstream `Framed`. Adapted from
  upstream `net.rs` (`Config`, geometry and cursor validation, handshake and frame loop).
- `tools/fixture-gen`: separate Cargo workspace (own lockfile) linking upstream
  `gliff-sw`; `synth`, `record`, `serve`, `describe`.
- Fixtures `tests/fixtures/streams/synthetic-{single420,dual420}` with manifests;
  `scripts/generate-fixtures.sh [--check]`; [fixture guide](../../tests/fixtures/README.md).
- Tests: 3 Annex B unit tests; 17 replay tests; 2 mock-peer tests; 1 portability test;
  1 fixture-tool unit test. `scripts/check.sh` runs all of them, the fixture check and the
  portability audit.
- Evidence: [`evidence/chroma-single420-vs-dual420.png`](evidence/chroma-single420-vs-dual420.png),
  decoded by upstream's reference decoder from the committed fixtures.

## Findings that change earlier assumptions

1. Header is two LE `u32` (body, payload), not one 8-byte length.
2. No configuration generation on the wire; pace-only `StreamConfig`s exist and must not
   reset the decoder. The client numbers decoder generations and config revisions.
3. `FrameAck` feeds byte-based rate control and is sent for every frame, even failed
   or dropped ones. There is no fixed in-flight frame window.
4. `extradata` is always empty; SPS/PPS precede every IDR in-band (measured on CPU
   output; GPU sources say the same and need a live capture to confirm).
5. Truncation inside a frame and clean EOF both surface as `Error::Closed`.
6. `Resize` below 320×240 is ignored by the server.
7. The clipboard spool sweep deletes live processes' spools on macOS (`/proc`).
8. CPU H.264 is Baseline with one slice per thread (≤ 4) and no periodic IDR in the
   observed 16 frames; GPU is High profile.

## Measured on the fixtures (upstream OpenH264 decoder)

| Mode | PSNR outside the chroma stripe | PSNR in the 1-px red/cyan stripe | Bytes (16 frames) |
| --- | --- | --- | --- |
| Single420 | 43.0–46.7 dB | 7.4 dB | 22 KB (main 20.1 KB) |
| Dual420 | 44.0–47.7 dB | 39.7–44.9 dB | 46 KB (main 20.1 KB + aux 24.3 KB) |

The main stream is byte-identical in both modes: Dual420 adds the aux stream without
changing the 4:2:0 picture, which is what lets the server drop aux on a ladder step.

## Acceptance status

| Criterion | Status |
| --- | --- |
| Contract/behaviour inventory and fixture manifest; API records for 04, cases for 03 | Done |
| macOS build logs for both targets without the Linux client stack | Done (`build/portability/`, summary in the audit) |
| Replay: partial reads/writes, oversized/truncated, unknown, version mismatch, config changes, main/aux | Done |
| ≥ 1 real Single420 and 1 real Dual420 capture parsed without Hyprland, provenance of the exact server | **Partial**: server-equivalent captures from upstream's CPU encoder and framing at the pinned SHA; no live `gliff-server` run. `record` is ready and tested against `serve` |
| CPU- and GPU-encoded real samples (SPS/PPS/extradata) | **Partial**: CPU encoder verified; GPU pending a VA-API/Vulkan host |
| No capability inferred from an enum | Done (`DecoderSupport`, Native444 rejection test) |

No Linux/Hyprland host was reachable from this machine (Docker is installed but its daemon
is stopped, and it would not provide a compositor or GPU encoder). Recording the live
captures is a short follow-up with the commands in the fixture guide; it should land
before task 07 relies on GPU (High profile) streams.

## Environment

macOS 27.0.1 on Apple Silicon, Xcode 27.1 (27A9275), Rust 1.90.0 via Homebrew `rustup`.
CI keeps Xcode 16.4. Fixtures were encoded with 4 OpenH264 threads.
