//! Server-to-client message reading with payload association.
//!
//! Upstream `Framed::read_msg` returns a message whose payload bytes must
//! then be read in the order the message declares them; unread payload is
//! discarded before the next message. This module performs those reads and
//! applies the handshake and video contract, so the session task and the
//! replay tests share one reader.

use bytes::Bytes;
use gliff_proto::{
    is_incompatible, version_mismatch, ClipboardMsg, OutputInfo, ServerMsg, SessionInfo,
    PROTOCOL_VERSION,
};
use gliff_transport::Framed;
use tokio::io::AsyncRead;

use crate::video::{
    ContractError, DecoderSupport, FrameDisposition, StreamConfigFields, StreamTracker,
    VideoConfig, VideoFrameHeader,
};

/// What the session reacts to, in wire order.
#[derive(Debug, Clone, PartialEq)]
pub enum ServerEvent {
    HelloAck {
        session: SessionInfo,
        outputs: Vec<OutputInfo>,
        features: Vec<String>,
    },
    /// Must be answered with `ClientMsg::Pong { t }` ahead of anything else.
    Ping {
        t: u64,
    },
    Pong {
        t: u64,
        server_now_ms: u64,
    },
    Config(VideoConfig),
    Frame(FrameDisposition),
    CursorShape {
        id: u32,
        width: u32,
        height: u32,
        hot_x: i32,
        hot_y: i32,
        /// `width * height` premultiplied ARGB words; `None` when the shape
        /// is malformed, which upstream ignores rather than failing.
        argb: Option<Bytes>,
    },
    CursorPos {
        x: f64,
        y: f64,
        shape_id: u32,
        visible: bool,
    },
    /// Clipboard control messages go to `gliff_transport::clipboard`; a
    /// `Data` chunk carries its payload.
    Clipboard {
        msg: ClipboardMsg,
        data: Option<Bytes>,
    },
    /// A recoverable server error (outside the incompatible range), such as
    /// `ERROR_SETUP`. The server closes the session after it.
    Error {
        code: u16,
        message: String,
    },
}

#[derive(Debug, thiserror::Error)]
pub enum SessionError {
    #[error(transparent)]
    Transport(#[from] gliff_transport::Error),
    #[error(transparent)]
    Contract(#[from] ContractError),
    #[error("{reason} (client protocol {client}, server protocol {server})")]
    VersionMismatch {
        client: u16,
        server: u16,
        reason: &'static str,
    },
    /// Codes 1..=255: reconnecting would fail the same way.
    #[error("incompatible server (code {code}): {message}")]
    Incompatible { code: u16, message: String },
    #[error("expected HelloAck first, got {0}")]
    UnexpectedFirstMessage(&'static str),
    #[error("the server sent a second HelloAck")]
    RepeatedHelloAck,
}

impl SessionError {
    /// Whether reconnecting cannot help.
    pub fn is_fatal_incompatibility(&self) -> bool {
        matches!(
            self,
            Self::VersionMismatch { .. } | Self::Incompatible { .. } | Self::Contract(_)
        )
    }
}

/// Reads server messages and turns them into [`ServerEvent`]s.
pub struct ServerReader<S> {
    framed: Framed<S>,
    tracker: StreamTracker,
    acked_hello: bool,
}

impl<S: AsyncRead + Unpin> ServerReader<S> {
    pub fn new(stream: S, support: DecoderSupport) -> Self {
        Self {
            framed: Framed::new(stream),
            tracker: StreamTracker::new(support),
            acked_hello: false,
        }
    }

    pub fn tracker(&self) -> &StreamTracker {
        &self.tracker
    }

    pub fn tracker_mut(&mut self) -> &mut StreamTracker {
        &mut self.tracker
    }

    /// Read the next event. `Err(Transport(Closed))` is a clean end of stream
    /// between messages; anything else is an error for this session.
    pub async fn next_event(&mut self) -> Result<ServerEvent, SessionError> {
        let msg: ServerMsg = self.framed.read_msg().await?;
        if let ServerMsg::Error {
            code,
            message,
            version,
        } = msg
        {
            return Err(match version {
                Some(server) if code == gliff_proto::ERROR_VERSION => {
                    SessionError::VersionMismatch {
                        client: PROTOCOL_VERSION,
                        server,
                        reason: version_mismatch(PROTOCOL_VERSION, server),
                    }
                }
                _ if is_incompatible(code) => SessionError::Incompatible { code, message },
                _ => return Ok(ServerEvent::Error { code, message }),
            });
        }
        if !self.acked_hello {
            let ServerMsg::HelloAck {
                version,
                session,
                outputs,
                features,
            } = msg
            else {
                return Err(SessionError::UnexpectedFirstMessage(name(&msg)));
            };
            if version != PROTOCOL_VERSION {
                return Err(SessionError::VersionMismatch {
                    client: PROTOCOL_VERSION,
                    server: version,
                    reason: version_mismatch(PROTOCOL_VERSION, version),
                });
            }
            self.acked_hello = true;
            return Ok(ServerEvent::HelloAck {
                session,
                outputs,
                features,
            });
        }
        let msg = match msg.into_clipboard() {
            Ok(msg) => {
                let data = match msg {
                    ClipboardMsg::Data { data_len, .. } => {
                        Some(self.framed.read_payload(data_len).await?)
                    }
                    _ => None,
                };
                return Ok(ServerEvent::Clipboard { msg, data });
            }
            Err(other) => other,
        };
        Ok(match msg {
            ServerMsg::Ping { t } => ServerEvent::Ping { t },
            ServerMsg::Pong { t, server_now_ms } => ServerEvent::Pong { t, server_now_ms },
            ServerMsg::StreamConfig {
                codec,
                chroma,
                pipeline,
                width,
                height,
                scale_milli,
                extradata,
                aux_extradata,
                view_width,
                view_height,
                fps_cap,
            } => ServerEvent::Config(
                self.tracker
                    .on_config(StreamConfigFields {
                        codec,
                        chroma,
                        pipeline,
                        width,
                        height,
                        scale_milli,
                        extradata: &extradata,
                        aux_extradata: aux_extradata.as_deref(),
                        view_width,
                        view_height,
                        fps_cap,
                    })?
                    .clone(),
            ),
            ServerMsg::VideoFrame {
                frame_id,
                pts_us,
                keyframe,
                damage,
                data_len,
                aux_len,
            } => {
                let header = VideoFrameHeader {
                    frame_id,
                    pts_us,
                    keyframe,
                    damage,
                    data_len,
                    aux_len,
                };
                self.tracker.check_header(&header)?;
                let main = self.framed.read_payload(data_len).await?;
                let aux = match aux_len {
                    0 => None,
                    n => Some(self.framed.read_payload(n).await?),
                };
                ServerEvent::Frame(self.tracker.on_frame(header, main, aux)?)
            }
            ServerMsg::CursorShape {
                id,
                width,
                height,
                hot_x,
                hot_y,
                argb_len,
            } => ServerEvent::CursorShape {
                id,
                width,
                height,
                hot_x,
                hot_y,
                argb: if cursor_payload_fits(width, height, argb_len) {
                    Some(self.framed.read_payload(argb_len).await?)
                } else {
                    None
                },
            },
            ServerMsg::CursorPos {
                x,
                y,
                shape_id,
                visible,
            } => ServerEvent::CursorPos {
                x,
                y,
                shape_id,
                visible,
            },
            ServerMsg::HelloAck { .. } => return Err(SessionError::RepeatedHelloAck),
            other => unreachable!("handled above: {}", name(&other)),
        })
    }
}

/// Largest cursor side the client accepts, as upstream `MAX_CURSOR`.
pub const MAX_CURSOR: u32 = 1024;

fn cursor_payload_fits(width: u32, height: u32, argb_len: u32) -> bool {
    (1..=MAX_CURSOR).contains(&width)
        && (1..=MAX_CURSOR).contains(&height)
        && u64::from(argb_len) == u64::from(width) * u64::from(height) * 4
}

fn name(msg: &ServerMsg) -> &'static str {
    match msg {
        ServerMsg::HelloAck { .. } => "HelloAck",
        ServerMsg::StreamConfig { .. } => "StreamConfig",
        ServerMsg::VideoFrame { .. } => "VideoFrame",
        ServerMsg::CursorShape { .. } => "CursorShape",
        ServerMsg::CursorPos { .. } => "CursorPos",
        ServerMsg::ClipboardOffer { .. } => "ClipboardOffer",
        ServerMsg::ClipboardRequest { .. } => "ClipboardRequest",
        ServerMsg::ClipboardData { .. } => "ClipboardData",
        ServerMsg::Pong { .. } => "Pong",
        ServerMsg::Error { .. } => "Error",
        ServerMsg::ClipboardAck { .. } => "ClipboardAck",
        ServerMsg::ClipboardAbort { .. } => "ClipboardAbort",
        ServerMsg::Ping { .. } => "Ping",
    }
}
