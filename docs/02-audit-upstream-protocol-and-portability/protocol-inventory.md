# Upstream protocol and behaviour inventory

Baseline: `omacom/gliff` at `58c742452ded3f10a2ce61f60eb4845f18205e29` (Gliff 0.4.1,
`PROTOCOL_VERSION = 1`, `FEATURES = []`). Paths are relative to `vendor/gliff/crates/`.
Symbols are cited instead of line numbers so the record survives small upstream edits;
task 03 re-checks each claim against a new pin.

**Reuse** means the app calls the upstream code as is. **Adapt** means the app
reimplements an upstream behaviour in `crates/gliff-client-core`, with attribution.
**Native** means Swift/AppKit implements it in a later task against this contract.

## Reuse boundary

| Upstream source | Symbols | Use | Notes |
| --- | --- | --- | --- |
| `gliff-proto/src/frame.rs` | `HEADER_LEN`, `MAX_FRAME_BODY`, `MAX_PAYLOAD`, `MAX_FRAME_PAYLOAD` | Reuse | Wire layout and limits |
| `gliff-proto/src/msg.rs` | `ClientMsg`, `ServerMsg`, `ClientCaps`, `Greeting`, `ERROR_*`, `is_incompatible`, `version_mismatch` | Reuse | Wire types stay behind the app API; Swift never sees them |
| `gliff-proto/src/cbor.rs` | `optional`, `known` | Reuse (indirect) | Forward-compatible decoding of enums |
| `gliff-proto/src/clipboard.rs` | `ClipboardMsg`, `Assembler`, `SendWindow`, `CHUNK`, `WINDOW`, `MAX_*` | Reuse | Pure state machines |
| `gliff-proto/src/chroma.rs`, `color.rs` | `split_yuv444`, `recombine_yuv444`, BT.709 | Reference | CPU reference for task 08's Metal recombination |
| `gliff-transport/src/lib.rs` | `Framed::{read_msg, read_payload, write_msg, write_msg_with_payloads}` | Reuse | Cancel-safe reads, vectored writes |
| `gliff-transport/src/ssh.rs` | `SshTarget`, `spawn_ssh` | Reuse | `ssh -T -o Compression=no -o IPQoS=lowdelay -- host gliff-server --stdio` |
| `gliff-transport/src/clipboard/` | `Transfers`, `files::{list_files, Spool, fetch_files}` | Reuse, with one macOS adapter | See [portability audit](portability-audit.md) (`Spool` sweep) |
| `gliff/src/net.rs` | `Config`, `validate_stream_size`, `validate_view_size`, `cursor_payload_fits`, handshake loop, frame loop | Adapt | `gliff-client-core::{events, video}`; the rest of `net.rs` is GTK/Vulkan |
| `gliff-sw` | `Encoder`, `Decoder` | Fixture tool only | Never in the app graph; used to encode and verify fixtures |
| `gliff-server`, `gliff-va`, `gliff-vk`, `hypr-*`, `gliff` | — | Not used | Linux server and client stack |

Licences: upstream is MIT (`vendor/gliff/LICENSE`, Kevin McConnell), preserved in
[`THIRD_PARTY_NOTICES.md`](../../THIRD_PARTY_NOTICES.md). The app's resolved Apple graph
(58 crates, see the audit) is MIT, MIT/Apache-2.0, Apache-2.0 WITH LLVM-exception
(`rustix`), Unicode-3.0 (`unicode-ident`), BlueOak-1.0.0 (`minicbor`) and MPL-2.0
(`uniffi`). The fixture tool additionally builds OpenH264 (BSD-2-Clause) from source;
it is a development tool and is not distributed.

## Framing

- Header is 8 bytes: **two little-endian `u32`** — `body_len` then `payload_len`
  (`frame.rs` module doc, `Framed::write_msg_with_payloads`). It is not one 8-byte
  length. The task brief's "8-byte little-endian lengths" is corrected here.
- Body: one CBOR message, minicbor positional encoding `[variant, [field0, field1, …]]`
  (`msg.rs` module doc). Field and variant numbers are `#[n]` positions; names never
  travel.
- Payload: raw bytes after the body, in the order the message declares them —
  `VideoFrame` main (`data_len`) then aux (`aux_len`); `CursorShape` ARGB (`argb_len`);
  `ClipboardData` chunk (`data_len`). `StreamConfig::extradata` is a CBOR byte string
  inside the body, not a payload.
- Limits: body ≤ `MAX_FRAME_BODY` (1 MiB); one payload ≤ `MAX_PAYLOAD` (64 MiB); frame
  payload ≤ `MAX_FRAME_PAYLOAD` (128 MiB). Both are checked from the header before any
  allocation (`BodyTooLarge`, `PayloadTooLarge`); a payload read beyond what the header
  carries is `PayloadOverrun`. Clipboard chunks are ≤ `CHUNK` (256 KiB).
- Unread payload is discarded before the next header (`payload_left`, `skip_left`).
- Partial I/O: `read_msg` is cancel-safe and resumes a parsed header or partially
  skipped payload; `write_all_vectored` resumes inside a slice after a short write.
- End of stream: `Error::Closed` is returned both for a clean EOF between frames and
  for a cut **inside** a frame. Upstream cannot tell them apart; the client must treat
  `Closed` as a disconnect, never as a complete message. Replay tests pin this.

## Compatibility rules

- Unknown **message** variant: skipped with its payload (`is_unknown_message`): only
  when the unknown index is the message's own variant.
- Unknown **enum value** inside a known message fails that message (decode error, fatal
  for the session), except optional enum fields (`cbor::optional`, e.g.
  `StreamConfig::pipeline`) and `Hello`'s enum lists (`cbor::known`).
- New messages or enum values are sent only to a peer that listed the introducing
  feature in the handshake. `FEATURES` is empty at this pin: the client sends
  `features()` and must not infer support for any optional behaviour.
- A new field takes the next number and is optional; an older peer ignores it.
- Version: the server reads the client's `Hello` as a `Greeting`; any other version gets
  `ServerMsg::Error { code: ERROR_VERSION, version: Some(server) }`. The head of `Hello`,
  the frame header and the first two `Error` fields never change.
- Error codes 1–255 are incompatibilities (`ERROR_VERSION` 1, `ERROR_NO_CHROMA` 2,
  `ERROR_NO_CODEC` 3): reconnecting fails the same way. `ERROR_SETUP` (256: no Hyprland,
  no output, pipeline failure) is retryable.

## Handshake and session start

Server order (`gliff-server/src/session.rs`, session start):

1. Client → `Hello { version, keymap, caps }`. `keymap` is XKB text or empty (server
   default: US). `caps`: `codecs`, `max_width/height`, `chroma` (preferred first),
   `features`.
2. Server checks version, codec and chroma (errors 1–3), finds Hyprland and the output
   (error 256), then → `HelloAck { version, session { headless, output }, outputs[{ name,
   width, height, scale_milli }], features }`.
3. Server → `Ping { t }`, pipelined behind `HelloAck` and never waited on. The client
   answers `Pong { t }` **before anything else** (upstream answers before GPU setup), to
   seed the server's RTT estimate.
4. Server → `StreamConfig`, then `CursorShape`/`CursorPos` and `VideoFrame`s.
5. Client may send `Ping { t }` at any time; the server answers `Pong { t, server_now_ms }`.
6. Client `Bye` ends the session. A second `Hello` is a server error.

The upstream client (`net.rs`) answers `Ping`s before the first `StreamConfig`, rejects
any other message before it, rejects a `HelloAck` version mismatch, and treats `Error`
1–255 as incompatible.

## Video stream

- `StreamConfig { codec, chroma, pipeline, width, height, scale_milli, extradata,
  aux_extradata, view_width, view_height, fps_cap }`. The server always sends `H264`,
  `extradata` empty and `aux_extradata` `None`: "parameter sets ride in-band on every
  keyframe" (`stream_config`).
- No configuration generation on the wire. `Config::update` (`net.rs`) rebuilds the
  decoder only when `(stream size, chroma)` changes; an fps-cap, view or scale change
  keeps it. The server sends a pace-only `StreamConfig` on a ladder step that changes
  only `fps_cap` (`apply_stream_params` → `send_config`), and a rebuild after resize or
  a chroma/scale step, each followed by a keyframe (`want_keyframe = true`).
- The ladder (`rate.rs::LEVELS`) can drop Dual420 to Single420 mid-session (`aux:
  false` levels) and reduce scale; a client that advertises both modes must handle a
  chroma change at the same size.
- `VideoFrame { frame_id, pts_us, keyframe, damage, data_len, aux_len }`: `frame_id`
  starts at 0 and increases by one per encoded frame for the whole session, across
  rebuilds; `pts_us` is the server's wall clock in µs (`now_ms() * 1000`), not a media
  clock; `damage` is the whole frame; `aux_len > 0` iff Dual420.
- Codec bitstream: Annex B with start codes. CPU (`gliff-sw::new_h264_encoder`):
  OpenH264 Baseline, screen-content real time, BT.709 VUI, bitrate RC, QP 12–35, one
  slice per encoder thread (≤ 4). GPU (`gliff-va`, `gliff-vk`): High profile, CABAC,
  one reference, no reordering, IDR only on demand. Measured on the fixtures (CPU):
  keyframes are `SPS, PPS, IDR×4` (4 slices), P frames `slice×4`, no periodic IDR in
  16 frames: only the first frame, forced (`RequestKeyframe`) and rebuild IDRs.
- Dual420 (AVC444-style): main = 4:2:0 of the 4:4:4 picture; aux packs the dropped
  chroma: aux Y top half = U of odd rows, bottom half = V of odd rows; aux U/V = U/V of
  even rows, odd columns (`chroma.rs::split_yuv444`). Both streams are full-size I420,
  encoded independently but forced to IDR together; the frame's `keyframe` follows the
  main stream.
- CPU defaults to Single420; `gliff-server --full-chroma` enables CPU Dual420. Native444,
  H.265, AV1 and RawBgra are declared enum values only: the server never selects them,
  and the client must not advertise them.
- Client geometry checks (`net.rs`): stream even, non-zero, ≤ 4096×4096; view ≤
  4096×4096 and at least half the stream on each side.

## Acknowledgement and pacing

- `FrameAck { frame_id, decoded_at_ms }`: the upstream client sends it right after each
  decode call, **whether the decode succeeded or not** ("Ack immediately so the server
  keeps pacing"), and requests a keyframe on a decode error.
- The server does not use a fixed frame window. `rate.rs::Link` records each sent frame's
  bytes; acks retire them (an ack for a later frame retires earlier ones), give delivery
  rate and RTT samples, and drive the bitrate and the ladder. Capture/encode waits on the
  byte cap of unacknowledged data (`cap_bytes`). A frame that is never acked keeps its
  bytes in flight until a later ack: missing acks stall the stream.
- `RequestKeyframe` sets `want_keyframe`; the next encoded frame is an IDR.

## Input, cursor and display

- `Key { keycode, pressed }`: Linux **evdev** keycode (XKB keycode − 8), injected through
  the server's virtual keyboard with the client's XKB keymap (`hypr-input`). `Keymap {
  keymap }` replaces it mid-session. macOS virtual keycodes and text insertion are not
  accepted.
- `PointerMotion { x, y }`: absolute, in the remote's **logical** space, which is
  `stream size / (scale_milli / 1000)`.
- `PointerButton { button, pressed }`: evdev `BTN_*` (`BTN_LEFT` 0x110, `BTN_RIGHT` 0x111,
  `BTN_MIDDLE` 0x112). `PointerAxis { axis, value, discrete, stop }`: `wl_pointer.axis`
  value; `discrete` present means a wheel (axis source wheel, `axis_discrete` click
  count), absent means finger/continuous; `stop` ends a scroll sequence
  (`hypr-input/src/thread.rs`).
- `Resize { width, height, scale }` (headless): clamped to `caps.max_*`, even, scale
  clamped to 0.5–4.0; sizes below 320×240 are ignored (`Session::resize`); headless
  outputs are capped at 4096 a side and 3840×2160 pixels (`HEADLESS_LIMIT`).
- `CursorShape { id, width, height, hot_x, hot_y, argb_len }` + premultiplied ARGB
  payload; the client ignores a shape whose payload is not `w × h × 4` or whose side
  exceeds 1024 (`cursor_payload_fits`). `CursorPos { x, y, shape_id, visible }` in logical
  coordinates.
- Mirror vs headless: `SessionInfo.headless`; mirror mode streams a named or main
  monitor (`--output`), headless creates `gliff-<pid>` sized to the client.

## Clipboard

Offer/request model (`gliff-proto/src/clipboard.rs`, `gliff-transport/src/clipboard`):
the side whose selection changed sends `Offer { serial, mime_types, files }`; the other
side proxies it and, on paste, sends `Request { id, serial, item }` (`Mime` or `File`
index). Data flows as `Data { id, offset, data_len, done }` chunks ≤ 256 KiB with ≤ 4
chunks unacknowledged (`Ack { id, received }`). Either side may `Abort { id }`; transfers
idle for 30 s are abandoned. Caps: 32 MiB per in-memory item, 4 GiB of files, 10 000
entries, 512 KiB of paths per offer. Files are listed by relative path and streamed into
a private spool. The engine runs in a tokio `LocalSet`; the app owns pasteboard I/O.

## Inferred-support guard

An enum value existing upstream is not support. The client contract
(`DecoderSupport`) lists exactly what the native client implements, rejects any
`StreamConfig` outside it, and the tests check Native444 is refused even though it is a
valid wire value.
