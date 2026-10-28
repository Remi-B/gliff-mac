//! Replay a capture through the client contract and print its manifest.

use std::path::Path;

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
    let synthetic = provenance["kind"] == "synthetic-server-equivalent";
    let png_dir = opts.optional_path("--png-dir");
    let mut reader = ServerReader::new(
        &bytes[..],
        DecoderSupport::h264(&[ChromaMode::Dual420, ChromaMode::Single420]),
    );
    let mut messages: Vec<Value> = Vec::new();
    let mut configs: Vec<Value> = Vec::new();
    let mut frames: Vec<Value> = Vec::new();
    let mut decoder: Option<gliff_sw::Decoder> = None;
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
                    decoder = Some(gliff_sw::Decoder::new(c.is_dual(), c.width, c.height)?);
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
                let decoded = decoder
                    .as_mut()
                    .ok_or("frame without decoder")?
                    .decode(&f.main, aux)?
                    .ok_or("the reference decoder held a Baseline picture")?;
                let mut entry = json!({
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
                    "decoded_width": decoded.width,
                    "decoded_height": decoded.height,
                    "decoded_bgra_sha256": hex(&decoded.pixels),
                });
                if synthetic {
                    let source = synth::source_frame(decoded.width, decoded.height, f.frame_id);
                    let (stripe, rest) =
                        split_stripe(&source, &decoded.pixels, decoded.width, decoded.height);
                    entry["chroma_stripe_psnr_db"] = json!(round2(stripe));
                    entry["rest_psnr_db"] = json!(round2(rest));
                }
                if let Some(dir) = &png_dir {
                    write_png(
                        &dir.join(format!("decoded-{:03}.png", f.frame_id)),
                        decoded.width,
                        decoded.height,
                        &decoded.pixels,
                    )?;
                }
                frames.push(entry);
            }
            ServerEvent::Frame(FrameDisposition::AwaitKeyframe { frame_id, .. }) => {
                return Err(
                    format!("frame {frame_id} is not decodable from the capture start").into(),
                )
            }
            _ => {}
        }
    }
    let name = opts
        .get("--name")
        .map(str::to_owned)
        .unwrap_or_else(|| path.file_name().unwrap().to_string_lossy().into_owned());
    let manifest = json!({
        "name": name,
        "file": path.file_name().unwrap().to_string_lossy(),
        "bytes": bytes.len(),
        "sha256": hex(&bytes),
        "provenance": provenance,
        "messages": messages,
        "configs": configs,
        "frames": frames,
    });
    println!("{}", serde_json::to_string_pretty(&manifest)?);
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
