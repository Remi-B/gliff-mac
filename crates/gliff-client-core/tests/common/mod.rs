//! Shared replay helpers: fixture loading and stream wrappers that split
//! reads and writes at arbitrary boundaries.

#![allow(dead_code)]

use std::io::IoSlice;
use std::path::PathBuf;
use std::pin::Pin;
use std::task::{Context, Poll};

use gliff_client_core::events::{ServerEvent, ServerReader, SessionError};
use gliff_client_core::video::DecoderSupport;
use gliff_proto::ChromaMode;
use serde_json::Value;
use sha2::{Digest, Sha256};
use tokio::io::{AsyncRead, AsyncWrite, ReadBuf};

pub const FIXTURES: [&str; 5] = [
    "synthetic-single420",
    "synthetic-dual420",
    "live-cpu-single420",
    "live-cpu-dual420",
    "live-gpu-dual420",
];

pub fn fixture_dir() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../tests/fixtures/streams")
}

pub struct Fixture {
    pub bytes: Vec<u8>,
    pub manifest: Value,
}

pub fn fixture(name: &str) -> Fixture {
    let dir = fixture_dir();
    let manifest: Value =
        serde_json::from_slice(&std::fs::read(dir.join(format!("{name}.json"))).unwrap()).unwrap();
    let bytes = std::fs::read(dir.join(manifest["file"].as_str().unwrap())).unwrap();
    Fixture { bytes, manifest }
}

pub fn sha256(bytes: &[u8]) -> String {
    Sha256::digest(bytes)
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect()
}

pub fn both_chroma() -> DecoderSupport {
    DecoderSupport::h264(&[ChromaMode::Dual420, ChromaMode::Single420])
}

/// Read every event until the stream ends; the error that ended it, if it
/// is not a clean close, is returned alongside.
pub async fn read_all<S: AsyncRead + Unpin>(
    reader: &mut ServerReader<S>,
) -> (Vec<ServerEvent>, Option<SessionError>) {
    let mut events = Vec::new();
    loop {
        match reader.next_event().await {
            Ok(e) => events.push(e),
            Err(SessionError::Transport(gliff_transport::Error::Closed)) => return (events, None),
            Err(e) => return (events, Some(e)),
        }
    }
}

/// Serves `data` in reads of at most `chunk` bytes, returning `Pending`
/// (and waking at once) before every other read, so `Framed` resumes from
/// every possible split point and across pending polls.
pub struct ChunkedReader {
    data: Vec<u8>,
    at: usize,
    chunk: usize,
    pend: bool,
}

impl ChunkedReader {
    pub fn new(data: Vec<u8>, chunk: usize) -> Self {
        Self {
            data,
            at: 0,
            chunk,
            pend: false,
        }
    }
}

impl AsyncRead for ChunkedReader {
    fn poll_read(
        mut self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buf: &mut ReadBuf<'_>,
    ) -> Poll<std::io::Result<()>> {
        self.pend = !self.pend;
        if self.pend {
            cx.waker().wake_by_ref();
            return Poll::Pending;
        }
        let n = self
            .chunk
            .min(buf.remaining())
            .min(self.data.len() - self.at);
        let at = self.at;
        buf.put_slice(&self.data[at..at + n]);
        self.at += n;
        Poll::Ready(Ok(()))
    }
}

/// Accepts at most `chunk` bytes per write, including vectored writes, so
/// upstream's `write_all_vectored` must resume inside a slice.
pub struct ShortWriter {
    pub written: Vec<u8>,
    chunk: usize,
}

impl ShortWriter {
    pub fn new(chunk: usize) -> Self {
        Self {
            written: Vec::new(),
            chunk,
        }
    }
}

impl AsyncWrite for ShortWriter {
    fn poll_write(
        mut self: Pin<&mut Self>,
        _: &mut Context<'_>,
        buf: &[u8],
    ) -> Poll<std::io::Result<usize>> {
        let n = buf.len().min(self.chunk);
        self.written.extend_from_slice(&buf[..n]);
        Poll::Ready(Ok(n))
    }

    fn poll_write_vectored(
        mut self: Pin<&mut Self>,
        _: &mut Context<'_>,
        bufs: &[IoSlice<'_>],
    ) -> Poll<std::io::Result<usize>> {
        let mut left = self.chunk;
        let mut n = 0;
        for b in bufs {
            let take = b.len().min(left);
            self.written.extend_from_slice(&b[..take]);
            n += take;
            left -= take;
            if left == 0 {
                break;
            }
        }
        Poll::Ready(Ok(n))
    }

    fn is_write_vectored(&self) -> bool {
        true
    }

    fn poll_flush(self: Pin<&mut Self>, _: &mut Context<'_>) -> Poll<std::io::Result<()>> {
        Poll::Ready(Ok(()))
    }

    fn poll_shutdown(self: Pin<&mut Self>, _: &mut Context<'_>) -> Poll<std::io::Result<()>> {
        Poll::Ready(Ok(()))
    }
}

/// One raw frame: header, CBOR body, payload.
pub fn raw_frame(body: &[u8], payload: &[u8]) -> Vec<u8> {
    let mut out = Vec::new();
    out.extend_from_slice(&(body.len() as u32).to_le_bytes());
    out.extend_from_slice(&(payload.len() as u32).to_le_bytes());
    out.extend_from_slice(body);
    out.extend_from_slice(payload);
    out
}

/// A frame header with arbitrary declared lengths and nothing after it.
pub fn raw_header(body_len: u32, payload_len: u32) -> Vec<u8> {
    let mut out = body_len.to_le_bytes().to_vec();
    out.extend_from_slice(&payload_len.to_le_bytes());
    out
}

pub fn encode<M: minicbor::Encode<()>>(msg: &M) -> Vec<u8> {
    minicbor::to_vec(msg).unwrap()
}

/// Byte offsets of each frame in a stream, walking the headers.
pub fn frame_offsets(stream: &[u8]) -> Vec<(usize, usize)> {
    let mut out = Vec::new();
    let mut at = 0;
    while at + 8 <= stream.len() {
        let body = u32::from_le_bytes(stream[at..at + 4].try_into().unwrap()) as usize;
        let payload = u32::from_le_bytes(stream[at + 4..at + 8].try_into().unwrap()) as usize;
        out.push((at, 8 + body + payload));
        at += 8 + body + payload;
    }
    assert_eq!(at, stream.len(), "fixture ends inside a frame");
    out
}
