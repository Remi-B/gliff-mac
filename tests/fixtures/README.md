# Contract fixtures

Server-to-client byte streams, exactly as they travel on the wire (frame headers, CBOR
bodies, payloads), with one JSON manifest each. No private desktop, clipboard or SSH data
is stored here. Every fixture replays without Hyprland.

| Fixture | Kind | Configs | Frames | Size |
| --- | --- | --- | --- | --- |
| `streams/synthetic-single420` | synthetic, server-equivalent | 320×192 (fps 30 → 15 pace-only), 384×240 rebuild | 16 (IDR at 0, 6, 10) | 22 KB |
| `streams/synthetic-dual420` | synthetic, server-equivalent | same, Dual420 | 16 main/aux pairs | 46 KB |

| `streams/live-cpu-single420` | live CPU | 640×480 → 800×600 | 45 | 61 KB |
| `streams/live-cpu-dual420` | live CPU | 640×480, pacing update | 20 pairs | 51 KB |
| `streams/live-gpu-dual420` | live VA-API/Vulkan | 640×480, pacing update | 20 pairs | 40 KB |

## Provenance classes

- `synthetic-server-equivalent`: deterministic BGRA frames encoded by upstream
  `gliff_sw::Encoder` (the encoder of `gliff-server --video cpu`) and framed by upstream
  `gliff_transport::Framed` in `gliff-server`'s message order, at the pinned SHA. Not a
  live capture: no Hyprland capture, rate control, writer scheduling or GPU encoder ran.
- `live-server-capture`: recorded from an unmodified `gliff-server --stdio` with
  `gliff-fixture-gen record`. Three are committed; see the table below.

## Manifest

Each `<name>.json` records: `file`, `bytes`, `sha256`; `provenance` (kind, upstream SHA,
generator command, encoder settings and thread count, OpenH264 version, toolchain, host);
`messages` (event order); `configs` (generation, revision, rebuild, codec, chroma,
pipeline, sizes, scale, fps cap); and per frame: generation, revision, `frame_id`,
`pts_us`, keyframe, main/aux length, SHA-256 and NAL unit types, decoded size,
`decoded_bgra_sha256` (upstream OpenH264 decoder + `gliff-sw` conversion), and for
synthetic streams PSNR against the source in the 1-px chroma stripe and elsewhere.

Expected decoded output: the H.264 pictures are bit-exact for any conforming decoder,
but BGRA conversion is not normative. The app's VideoToolbox decode with its Metal
conversion (task 07) and Dual420 recombination (task 08) reproduce
`decoded_bgra_sha256` byte for byte, since they use upstream's integer arithmetic; the
synthetic manifests' PSNR figures are also checked against the generator's source
picture, within the rounding of the manifest (0.01 dB).

## Regenerating and checking

```bash
scripts/generate-fixtures.sh          # rewrite streams and manifests
scripts/generate-fixtures.sh --check  # replay through record/serve and compare
```

OpenH264 cuts one slice per encoder thread (`min(CPUs, 4)`) and uses per-architecture
SIMD, so bytes are reproducible for a given thread count and architecture; `--check`
compares a fresh generation only when both match the manifest. On every host it replays
the committed streams through `record`/`serve` and re-describes them, so the committed
manifests are always checked against their streams.

Live capture setup, commands and decoded evidence: [live validation](../../docs/02-audit-upstream-protocol-and-portability/live-validation.md).
`--check` also re-describes and byte-for-byte replays all committed live captures.

## Recording a live server

On a Linux/Hyprland host running the pinned server:

```bash
cargo build --release --locked --manifest-path tools/fixture-gen/Cargo.toml
G=tools/fixture-gen/target/release/gliff-fixture-gen
$G record --ssh HOST --server-arg --headless --server-arg --video --server-arg cpu \
  --chroma single420 --frames 30 --resize-after 10 --resize 1280x800 \
  --out tests/fixtures/streams/live-cpu-single420.gliffstream
$G record --ssh HOST --server-arg --video --server-arg cpu --server-arg --full-chroma \
  --chroma dual420 --frames 30 --out tests/fixtures/streams/live-cpu-dual420.gliffstream
# Repeat with --server-arg --video --server-arg gpu on a VA-API/Vulkan host.
$G describe tests/fixtures/streams/live-cpu-single420.gliffstream \
  --name live-cpu-single420 --provenance '{"kind":"live-server-capture", ...}'
```

The recorder behaves as a minimal client: `Hello` with only the requested chroma mode,
`Pong` first, a `FrameAck` after each reference decode, `RequestKeyframe` when needed,
then `Bye`. It keeps the bytes up to the last complete requested frame. Record the
server's `git rev-parse HEAD`, build profile, `--video` tier, GPU/driver, Hyprland
version and output in the provenance before committing, and capture an output that
shows only synthetic content (for example a fresh headless output with a test
pattern). `--resize` only applies to headless sessions and is ignored below 320×240.
