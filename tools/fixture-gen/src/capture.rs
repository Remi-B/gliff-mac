//! Record a live server's byte stream, and replay one to a client.

use std::path::Path;
use std::pin::Pin;
use std::sync::{Arc, Mutex};
use std::task::{Context, Poll};
use std::time::{SystemTime, UNIX_EPOCH};

use gliff_client_core::events::{ServerEvent, ServerReader};
use gliff_client_core::video::{DecoderSupport, FrameDisposition};
use gliff_proto::frame::HEADER_LEN;
use gliff_proto::{features, ClientCaps, ClientMsg, Codec, Greeting, PROTOCOL_VERSION};
use gliff_transport::{Framed, SshTarget};
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWriteExt, ReadBuf};
use tokio::process::Command;

use crate::{Opts, Result};

/// Copies every byte read from the server, exactly as it arrived.
struct Tee<R> {
    inner: R,
    copy: Arc<Mutex<Vec<u8>>>,
}

impl<R: AsyncRead + Unpin> AsyncRead for Tee<R> {
    fn poll_read(
        mut self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buf: &mut ReadBuf<'_>,
    ) -> Poll<std::io::Result<()>> {
        let before = buf.filled().len();
        let poll = Pin::new(&mut self.inner).poll_read(cx, buf);
        if poll.is_ready() {
            let new = buf.filled()[before..].to_vec();
            self.copy.lock().unwrap().extend_from_slice(&new);
        }
        poll
    }
}

pub async fn record(opts: &mut Opts) -> Result<()> {
    let chroma = opts.chroma()?;
    let frames: u64 = opts.require("--frames")?.parse()?;
    let out = opts.path("--out")?;
    let resize_after: Option<u64> = opts.get("--resize-after").map(str::parse).transpose()?;
    let resize = opts.get("--resize").map(parse_size).transpose()?;
    let (mut child, stdin, stdout) = if let Some(host) = opts.get("--ssh") {
        let mut target = SshTarget::new(host);
        target.ssh_args = opts.all("--ssh-arg");
        target.server_args = opts.all("--server-arg");
        let s = gliff_transport::spawn_ssh(&target)?;
        (s.child, s.stdin, s.stdout)
    } else {
        let [program, args @ ..] = opts.command() else {
            return Err("record needs --ssh HOST or --command PROGRAM".into());
        };
        let mut child = Command::new(program)
            .args(args)
            .stdin(std::process::Stdio::piped())
            .stdout(std::process::Stdio::piped())
            .kill_on_drop(true)
            .spawn()?;
        let stdin = child.stdin.take().expect("piped");
        let stdout = child.stdout.take().expect("piped");
        (child, stdin, stdout)
    };
    let copy = Arc::new(Mutex::new(Vec::new()));
    let mut reader = ServerReader::new(
        Tee {
            inner: stdout,
            copy: copy.clone(),
        },
        DecoderSupport::h264(&[chroma]),
    );
    let mut writer = Framed::new(stdin);
    writer
        .write_msg(&ClientMsg::Hello {
            version: PROTOCOL_VERSION,
            keymap: String::new(),
            caps: ClientCaps {
                codecs: vec![Codec::H264],
                max_width: 3840,
                max_height: 2160,
                chroma: vec![chroma],
                features: features(),
            },
        })
        .await?;
    let mut decoder: Option<gliff_sw::Decoder> = None;
    let mut seen = 0u64;
    while seen < frames {
        match reader.next_event().await? {
            ServerEvent::Ping { t } => writer.write_msg(&ClientMsg::Pong { t }).await?,
            ServerEvent::Config(c) => {
                eprintln!(
                    "config {}: {:?} {:?} {}x{}",
                    c.generation, c.chroma, c.pipeline, c.width, c.height
                );
                if c.rebuild {
                    decoder = Some(gliff_sw::Decoder::new(c.is_dual(), c.width, c.height)?);
                }
            }
            ServerEvent::Frame(FrameDisposition::Decode(f)) => {
                // Ack after decoding, like the upstream client, so the
                // server paces this capture as it would a real viewer.
                if let Some(d) = decoder.as_mut() {
                    d.decode(&f.main, f.aux.as_deref().unwrap_or_default())?;
                }
                writer
                    .write_msg(&ClientMsg::FrameAck {
                        frame_id: f.frame_id,
                        decoded_at_ms: now_ms(),
                    })
                    .await?;
                seen += 1;
                if Some(seen) == resize_after {
                    if let Some((width, height)) = resize {
                        writer
                            .write_msg(&ClientMsg::Resize {
                                width,
                                height,
                                scale: 1.0,
                            })
                            .await?;
                    }
                }
            }
            ServerEvent::Frame(FrameDisposition::AwaitKeyframe {
                frame_id,
                request_keyframe,
            }) => {
                writer
                    .write_msg(&ClientMsg::FrameAck {
                        frame_id,
                        decoded_at_ms: now_ms(),
                    })
                    .await?;
                if request_keyframe {
                    writer.write_msg(&ClientMsg::RequestKeyframe).await?;
                }
            }
            ServerEvent::Error { code, message } => {
                return Err(format!("server error {code}: {message}").into())
            }
            _ => {}
        }
    }
    let _ = writer.write_msg(&ClientMsg::Bye).await;
    drop(writer);
    let _ = child.start_kill();
    let raw = copy.lock().unwrap().clone();
    let cut = complete_messages(&raw, frames);
    tokio::fs::write(&out, &raw[..cut]).await?;
    eprintln!("recorded {seen} frames, {cut} bytes to {}", out.display());
    Ok(())
}

/// Length of the prefix of `raw` that ends right after the `frames`-th
/// video frame, or after its last complete frame, walking frame headers.
/// Bytes read ahead are dropped.
pub fn complete_messages(raw: &[u8], frames: u64) -> usize {
    let mut at = 0usize;
    let mut video = 0u64;
    while at + HEADER_LEN <= raw.len() {
        let body = u32::from_le_bytes(raw[at..at + 4].try_into().unwrap()) as usize;
        let payload = u32::from_le_bytes(raw[at + 4..at + 8].try_into().unwrap()) as usize;
        let end = at + HEADER_LEN + body + payload;
        if end > raw.len() {
            break;
        }
        // `[2, [...]]`: array head 0x82 then the variant index.
        if raw.get(at + HEADER_LEN..at + HEADER_LEN + 2) == Some(&[0x82, 0x02]) {
            video += 1;
        }
        at = end;
        if video == frames {
            break;
        }
    }
    at
}

/// Serve a capture to one client on stdio: read its `Hello`, then send the
/// recorded bytes, answering nothing and draining what the client sends.
pub async fn serve(path: &Path) -> Result<()> {
    let bytes = tokio::fs::read(path).await?;
    let mut input = Framed::new(tokio::io::stdin());
    match input.read_msg::<Greeting>().await? {
        Greeting::Hello { .. } => {}
        Greeting::OtherVersion(v) => return Err(format!("client protocol {v}").into()),
    }
    let drain = tokio::spawn(async move {
        let mut stdin = input.into_inner();
        let mut sink = [0u8; 4096];
        while matches!(stdin.read(&mut sink).await, Ok(n) if n > 0) {}
    });
    let mut stdout = tokio::io::stdout();
    stdout.write_all(&bytes).await?;
    stdout.flush().await?;
    drain.await?;
    Ok(())
}

fn parse_size(s: &str) -> Result<(u32, u32)> {
    let (w, h) = s.split_once('x').ok_or("--resize WxH")?;
    Ok((w.parse()?, h.parse()?))
}

fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as u64
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cuts_after_the_requested_video_frame() {
        // body [2, [0]] is 0x82 0x02 0x81 0x00 (not a full VideoFrame, but
        // only the head matters to the cut).
        let frame = [4u8, 0, 0, 0, 1, 0, 0, 0, 0x82, 0x02, 0x81, 0x00, 0xaa];
        let ping = [4u8, 0, 0, 0, 0, 0, 0, 0, 0x82, 0x0c, 0x81, 0x00];
        let mut raw = ping.to_vec();
        raw.extend_from_slice(&frame);
        raw.extend_from_slice(&frame);
        raw.extend_from_slice(&frame[..5]);
        assert_eq!(complete_messages(&raw, 1), ping.len() + frame.len());
        assert_eq!(complete_messages(&raw, 5), ping.len() + 2 * frame.len());
    }
}
