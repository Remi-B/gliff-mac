//! Server-equivalent synthetic stream: upstream CPU encoder and framing, in
//! the message order of `gliff-server`'s session (`session.rs`): `HelloAck`,
//! `Ping`, `StreamConfig`, cursor, frames; a headless resize rebuilds the
//! encoder and sends a new `StreamConfig` followed by an IDR.

use std::path::{Path, PathBuf};

use gliff_proto::{
    features, ChromaMode, Codec, OutputInfo, Rect, ServerMsg, SessionInfo, VideoPipeline,
    PROTOCOL_VERSION,
};
use gliff_sw::{Encoder, EncoderSettings};
use gliff_transport::Framed;

use crate::Result;

/// Fixed wall clock so the stream is byte-for-byte reproducible.
pub const EPOCH_MS: u64 = 1_790_000_000_000;
pub const FPS: u32 = 30;
/// The next ladder level's fps cap (upstream `rate::LEVELS[2]`).
pub const PACED_FPS: u32 = 15;
pub const BITRATE: u32 = 1_500_000;
pub const OUTPUT: &str = "HEADLESS-1";
/// Two configurations: the session start, then a headless resize (the
/// server ignores resizes below 320x240, upstream `Session::resize`).
pub const SEGMENTS: [Segment; 2] = [
    Segment {
        width: 320,
        height: 192,
        frames: 10,
        forced_keyframe: Some(6),
        pace_change_after: Some(7),
    },
    Segment {
        width: 384,
        height: 240,
        frames: 6,
        forced_keyframe: None,
        pace_change_after: None,
    },
];

pub struct Segment {
    pub width: u32,
    pub height: u32,
    pub frames: u64,
    /// Frame index answering a simulated `RequestKeyframe`.
    pub forced_keyframe: Option<u64>,
    /// Frame index after which the ladder lowers the fps cap: a pace-only
    /// `StreamConfig` that keeps the encoder (upstream `apply_stream_params`).
    pub pace_change_after: Option<u64>,
}

pub async fn run(chroma: ChromaMode, out: &Path, png_dir: Option<PathBuf>) -> Result<()> {
    let file = tokio::fs::File::create(out).await?;
    let mut w = Framed::new(file);
    let first = &SEGMENTS[0];
    w.write_msg(&ServerMsg::HelloAck {
        version: PROTOCOL_VERSION,
        session: SessionInfo {
            headless: true,
            output: OUTPUT.into(),
        },
        outputs: vec![OutputInfo {
            name: OUTPUT.into(),
            width: first.width,
            height: first.height,
            scale_milli: 1000,
        }],
        features: features(),
    })
    .await?;
    w.write_msg(&ServerMsg::Ping { t: EPOCH_MS }).await?;
    let mut frame_id = 0u64;
    for (index, segment) in SEGMENTS.iter().enumerate() {
        w.write_msg(&stream_config(chroma, segment, FPS)).await?;
        if index == 0 {
            let argb = cursor_argb();
            w.write_msg_with_payloads(
                &ServerMsg::CursorShape {
                    id: 1,
                    width: 16,
                    height: 16,
                    hot_x: 1,
                    hot_y: 1,
                    argb_len: argb.len() as u32,
                },
                &[&argb],
            )
            .await?;
        }
        let mut encoder = Encoder::new(
            EncoderSettings {
                width: segment.width,
                height: segment.height,
                bitrate: BITRATE,
                framerate: FPS,
            },
            chroma == ChromaMode::Dual420,
        )?;
        for i in 0..segment.frames {
            let bgra = source_frame(segment.width, segment.height, frame_id);
            let forced = segment.forced_keyframe == Some(i);
            let encoded = encoder.encode_bgra(&bgra, forced)?;
            let aux = encoded.aux.unwrap_or_default();
            w.write_msg_with_payloads(
                &ServerMsg::VideoFrame {
                    frame_id,
                    pts_us: pts_us(frame_id),
                    keyframe: encoded.keyframe,
                    damage: vec![Rect {
                        x: 0,
                        y: 0,
                        width: segment.width as i32,
                        height: segment.height as i32,
                    }],
                    data_len: encoded.main.len() as u32,
                    aux_len: aux.len() as u32,
                },
                &[&encoded.main, &aux],
            )
            .await?;
            if i == 2 {
                w.write_msg(&ServerMsg::CursorPos {
                    x: 40.5,
                    y: 30.25,
                    shape_id: 1,
                    visible: true,
                })
                .await?;
                w.write_msg(&ServerMsg::Pong {
                    t: EPOCH_MS + 50,
                    server_now_ms: EPOCH_MS + 60,
                })
                .await?;
            }
            if segment.pace_change_after == Some(i) {
                w.write_msg(&stream_config(chroma, segment, PACED_FPS))
                    .await?;
            }
            if let Some(dir) = &png_dir {
                crate::describe::write_png(
                    &dir.join(format!("source-{frame_id:03}.png")),
                    segment.width,
                    segment.height,
                    &bgra,
                )?;
            }
            frame_id += 1;
        }
    }
    Ok(())
}

pub fn pts_us(frame_id: u64) -> u64 {
    EPOCH_MS * 1000 + frame_id * 1_000_000 / u64::from(FPS)
}

fn stream_config(chroma: ChromaMode, s: &Segment, fps_cap: u32) -> ServerMsg {
    // As upstream `stream_config`: parameter sets ride in-band, so
    // extradata is empty; no downscale, so the view box is the stream size.
    ServerMsg::StreamConfig {
        codec: Codec::H264,
        chroma,
        pipeline: Some(VideoPipeline::Cpu),
        width: s.width,
        height: s.height,
        scale_milli: 1000,
        extradata: Vec::new(),
        aux_extradata: None,
        view_width: s.width,
        view_height: s.height,
        fps_cap,
    }
}

/// Deterministic BGRA content that stresses what each chroma mode keeps: a
/// smooth gradient, a moving saturated block, one-pixel red/cyan columns and
/// a black/white checker resembling text.
pub fn source_frame(width: u32, height: u32, frame_id: u64) -> Vec<u8> {
    let (w, h) = (width as usize, height as usize);
    let mut px = vec![0u8; w * h * 4];
    let block_x = (frame_id as usize * 12) % (w - 48);
    for y in 0..h {
        for x in 0..w {
            let (mut r, mut g, mut b) = ((x * 255 / w) as u8, (y * 255 / h) as u8, 128u8);
            if (h / 2..h / 2 + 24).contains(&y) {
                (r, g, b) = if x % 2 == 0 {
                    (230, 20, 20)
                } else {
                    (20, 230, 230)
                };
            } else if (h / 4..h / 4 + 20).contains(&y) && (16..w / 2).contains(&x) {
                let on = ((x / 2) + (y / 2)) % 2 == 0;
                (r, g, b) = if on { (250, 250, 250) } else { (10, 10, 10) };
            }
            if (block_x..block_x + 48).contains(&x) && (h - 48..h - 16).contains(&y) {
                (r, g, b) = if frame_id.is_multiple_of(2) {
                    (20, 40, 220)
                } else {
                    (220, 180, 20)
                };
            }
            let i = (y * w + x) * 4;
            px[i..i + 4].copy_from_slice(&[b, g, r, 255]);
        }
    }
    px
}

/// A 16x16 white arrow with a black outline, premultiplied ARGB words in
/// little-endian byte order as the server sends them.
fn cursor_argb() -> Vec<u8> {
    let mut out = Vec::with_capacity(16 * 16 * 4);
    for y in 0..16i32 {
        for x in 0..16i32 {
            let inside = x <= y && x + y / 2 < 12;
            let edge = inside && (x == 0 || x == y || x + y / 2 == 11 || y == 15);
            let argb: u32 = match (inside, edge) {
                (true, true) => 0xff00_0000,
                (true, false) => 0xffff_ffff,
                _ => 0,
            };
            out.extend_from_slice(&argb.to_le_bytes());
        }
    }
    out
}
