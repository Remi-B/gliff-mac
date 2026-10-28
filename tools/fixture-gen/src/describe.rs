//! Replay a capture through the client contract and print its manifest.

use std::collections::VecDeque;
use std::path::{Path, PathBuf};

use gliff_client_core::annexb;
use gliff_client_core::events::{ServerEvent, ServerReader};
use gliff_client_core::video::{DecoderSupport, FrameDisposition};
use gliff_proto::ChromaMode;
use serde_json::{json, Value};
use sha2::{Digest, Sha256};

use crate::{synth, Opts, Result};

pub async fn run(opts: &Opts) -> Result<()> {
    let path = opts.positional(0)?;
    let bytes = tokio::fs::read(&path).await?;
    let provenance: Value = match opts.get("--provenance") {
        Some(p) => serde_json::from_str(p)?,
        None => json!({}),
    };
    let name = opts
        .get("--name")
        .map(str::to_owned)
        .unwrap_or_else(|| path.file_name().unwrap().to_string_lossy().into_owned());
    let mut manifest = describe(&bytes, provenance, opts.optional_path("--png-dir")).await?;
    manifest["name"] = json!(name);
    manifest["file"] = json!(path.file_name().unwrap().to_string_lossy());
    println!("{}", serde_json::to_string_pretty(&manifest)?);
    Ok(())
}

/// The reference decoder of the current generation, and the frames whose
/// picture it has not returned yet. A High-profile stream comes out one
/// access unit late, so pictures are matched to frames in decode order.
struct Reference {
    decoder: gliff_sw::Decoder,
    waiting: VecDeque<usize>,
}

pub async fn describe(bytes: &[u8], provenance: Value, png_dir: Option<PathBuf>) -> Result<Value> {
    // `Closed` also ends a stream cut inside a frame: refuse those.
    let complete = crate::capture::complete_messages(bytes, u64::MAX);
    if complete != bytes.len() {
        return Err(format!(
            "the capture ends inside a frame: {} trailing bytes after byte {complete}",
            bytes.len() - complete
        )
        .into());
    }
    let synthetic = provenance["kind"] == "synthetic-server-equivalent";
    let mut reader = ServerReader::new(
        bytes,
        DecoderSupport::h264(&[ChromaMode::Dual420, ChromaMode::Single420]),
    );
    let mut messages: Vec<Value> = Vec::new();
    let mut configs: Vec<Value> = Vec::new();
    let mut frames: Vec<Value> = Vec::new();
    let mut reference: Option<Reference> = None;
    loop {
        let event = match reader.next_event().await {
            Ok(e) => e,
            Err(gliff_client_core::events::SessionError::Transport(
                gliff_transport::Error::Closed,
            )) => break,
            Err(e) => return Err(e.into()),
        };
        messages.push(json!(kind(&event)));
        match event {
            ServerEvent::Config(c) => {
                if c.rebuild {
                    if let Some(old) = reference.take() {
                        drain(old, &mut frames, synthetic, png_dir.as_deref())?;
                    }
                    reference = Some(Reference {
                        decoder: gliff_sw::Decoder::new(c.is_dual(), c.width, c.height)?,
                        waiting: VecDeque::new(),
                    });
                }
                configs.push(json!({
                    "generation": c.generation,
                    "revision": c.revision,
                    "rebuild": c.rebuild,
                    "codec": format!("{:?}", c.codec),
                    "chroma": format!("{:?}", c.chroma),
                    "pipeline": c.pipeline.map(|p| p.label()),
                    "width": c.width,
                    "height": c.height,
                    "view_width": c.view_width,
                    "view_height": c.view_height,
                    "scale_milli": c.scale_milli,
                    "fps_cap": c.fps_cap,
                }));
            }
            ServerEvent::Frame(FrameDisposition::Decode(f)) => {
                let aux = f.aux.as_deref().unwrap_or_default();
                frames.push(json!({
                    "generation": f.generation,
                    "revision": f.revision,
                    "frame_id": f.frame_id,
                    "pts_us": f.pts_us,
                    "keyframe": f.keyframe,
                    "main_len": f.main.len(),
                    "main_sha256": hex(&f.main),
                    "main_nal_types": annexb::nal_types(&f.main)?,
                    "aux_len": aux.len(),
                    "aux_sha256": f.aux.as_deref().map(hex),
                    "aux_nal_types": f.aux.as_deref().map(annexb::nal_types).transpose()?,
                }));
                let r = reference.as_mut().ok_or("frame without decoder")?;
                r.waiting.push_back(frames.len() - 1);
                if let Some(picture) = r.decoder.decode(&f.main, aux)? {
                    let index = r.waiting.pop_front().expect("a waiting frame");
                    fill(&mut frames[index], &picture, synthetic, png_dir.as_deref())?;
                }
            }
            ServerEvent::Frame(FrameDisposition::AwaitKeyframe { frame_id, .. }) => {
                return Err(
                    format!("frame {frame_id} is not decodable from the capture start").into(),
                )
            }
            _ => {}
        }
    }
    if let Some(r) = reference.take() {
        drain(r, &mut frames, synthetic, png_dir.as_deref())?;
    }
    Ok(json!({
        "bytes": bytes.len(),
        "sha256": hex(bytes),
        "provenance": provenance,
        "messages": messages,
        "configs": configs,
        "frames": frames,
    }))
}

/// Flush the pictures a decoder still holds into their frames; every frame
/// must have produced one.
fn drain(
    mut r: Reference,
    frames: &mut [Value],
    synthetic: bool,
    png_dir: Option<&Path>,
) -> Result<()> {
    while let Some(&index) = r.waiting.front() {
        let Some(picture) = r.decoder.flush()? else {
            let id = &frames[index]["frame_id"];
            return Err(format!("the reference decoder produced no picture for frame {id}").into());
        };
        r.waiting.pop_front();
        fill(&mut frames[index], &picture, synthetic, png_dir)?;
    }
    Ok(())
}

fn fill(
    entry: &mut Value,
    decoded: &gliff_sw::BgraFrame,
    synthetic: bool,
    png_dir: Option<&Path>,
) -> Result<()> {
    let frame_id = entry["frame_id"].as_u64().expect("frame id");
    entry["decoded_width"] = json!(decoded.width);
    entry["decoded_height"] = json!(decoded.height);
    entry["decoded_bgra_sha256"] = json!(hex(&decoded.pixels));
    if synthetic {
        let source = synth::source_frame(decoded.width, decoded.height, frame_id);
        let (stripe, rest) = split_stripe(&source, &decoded.pixels, decoded.width, decoded.height);
        entry["chroma_stripe_psnr_db"] = json!(round2(stripe));
        entry["rest_psnr_db"] = json!(round2(rest));
    }
    if let Some(dir) = png_dir {
        write_png(
            &dir.join(format!("decoded-{frame_id:03}.png")),
            decoded.width,
            decoded.height,
            &decoded.pixels,
        )?;
    }
    Ok(())
}

fn kind(e: &ServerEvent) -> &'static str {
    match e {
        ServerEvent::HelloAck { .. } => "HelloAck",
        ServerEvent::Ping { .. } => "Ping",
        ServerEvent::Pong { .. } => "Pong",
        ServerEvent::Config(_) => "StreamConfig",
        ServerEvent::Frame(_) => "VideoFrame",
        ServerEvent::CursorShape { .. } => "CursorShape",
        ServerEvent::CursorPos { .. } => "CursorPos",
        ServerEvent::Clipboard { .. } => "Clipboard",
        ServerEvent::Error { .. } => "Error",
    }
}

fn hex(bytes: &[u8]) -> String {
    Sha256::digest(bytes)
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect()
}

fn round2(v: f64) -> f64 {
    (v * 100.0).round() / 100.0
}

/// PSNR over the colour channels of two BGRA images.
fn psnr(a: &[u8], b: &[u8]) -> f64 {
    let (sum, n) = a
        .chunks_exact(4)
        .zip(b.chunks_exact(4))
        .flat_map(|(p, q)| (0..3).map(move |c| f64::from(p[c]) - f64::from(q[c])))
        .fold((0.0, 0usize), |(s, n), d| (s + d * d, n + 1));
    let mse = sum / n.max(1) as f64;
    if mse == 0.0 {
        return 99.0;
    }
    10.0 * (255.0 * 255.0 / mse).log10()
}

/// PSNR over the one-pixel red/cyan columns, where 4:2:0 loses colour, and
/// over the rest of the picture.
fn split_stripe(a: &[u8], b: &[u8], width: u32, height: u32) -> (f64, f64) {
    let row = width as usize * 4;
    let start = height as usize / 2 * row;
    let end = start + 24 * row;
    let stripe = psnr(&a[start..end], &b[start..end]);
    let rest_a = [&a[..start], &a[end..]].concat();
    let rest_b = [&b[..start], &b[end..]].concat();
    (stripe, psnr(&rest_a, &rest_b))
}

pub fn write_png(path: &Path, width: u32, height: u32, bgra: &[u8]) -> Result<()> {
    let rgba: Vec<u8> = bgra
        .chunks_exact(4)
        .flat_map(|p| [p[2], p[1], p[0], 255])
        .collect();
    let file = std::io::BufWriter::new(std::fs::File::create(path)?);
    let mut encoder = png::Encoder::new(file, width, height);
    encoder.set_color(png::ColorType::Rgba);
    encoder.set_depth(png::BitDepth::Eight);
    encoder.write_header()?.write_image_data(&rgba)?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use gliff_proto::{Codec, ServerMsg, SessionInfo, PROTOCOL_VERSION};
    use gliff_transport::Framed;

    /// Upstream's x264 High-profile test stream (64x64, IDR then P): its
    /// first picture stays in OpenH264's reorder buffer.
    const HIGH_PROFILE: &[u8] =
        include_bytes!("../../../vendor/gliff/crates/gliff-va/src/h264/testdata/x264-64x64.264");

    async fn high_profile_stream() -> Vec<u8> {
        let p_slice = HIGH_PROFILE
            .windows(4)
            .position(|w| w[..3] == [0, 0, 1] && w[3] & 0x1f == 1)
            .expect("a P slice");
        let split = if HIGH_PROFILE[p_slice - 1] == 0 {
            p_slice - 1
        } else {
            p_slice
        };
        let units = [
            (&HIGH_PROFILE[..split], true),
            (&HIGH_PROFILE[split..], false),
        ];
        let mut w = Framed::new(Vec::new());
        w.write_msg(&ServerMsg::HelloAck {
            version: PROTOCOL_VERSION,
            session: SessionInfo {
                headless: true,
                output: "x".into(),
            },
            outputs: vec![],
            features: vec![],
        })
        .await
        .unwrap();
        w.write_msg(&ServerMsg::StreamConfig {
            codec: Codec::H264,
            chroma: ChromaMode::Single420,
            pipeline: None,
            width: 64,
            height: 64,
            scale_milli: 1000,
            extradata: vec![],
            aux_extradata: None,
            view_width: 64,
            view_height: 64,
            fps_cap: 30,
        })
        .await
        .unwrap();
        for (frame_id, (unit, keyframe)) in units.into_iter().enumerate() {
            w.write_msg_with_payloads(
                &ServerMsg::VideoFrame {
                    frame_id: frame_id as u64,
                    pts_us: 0,
                    keyframe,
                    damage: vec![],
                    data_len: unit.len() as u32,
                    aux_len: 0,
                },
                &[unit],
            )
            .await
            .unwrap();
        }
        w.into_inner()
    }

    #[tokio::test]
    async fn a_delayed_high_profile_picture_is_matched_to_its_frame() {
        let manifest = describe(&high_profile_stream().await, json!({}), None)
            .await
            .unwrap();
        let frames = manifest["frames"].as_array().unwrap();
        assert_eq!(frames.len(), 2);
        for f in frames {
            assert_eq!(f["decoded_width"], 64, "{f}");
            assert!(f["decoded_bgra_sha256"].is_string());
        }
    }

    #[tokio::test]
    async fn a_capture_cut_inside_a_frame_is_refused() {
        let stream = high_profile_stream().await;
        let err = describe(&stream[..stream.len() - 1], json!({}), None)
            .await
            .unwrap_err();
        assert!(err.to_string().contains("ends inside a frame"), "{err}");
    }
}
