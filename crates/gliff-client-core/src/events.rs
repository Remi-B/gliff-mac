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
    /// A message whose payload is still being read, kept across a
    /// cancelled `next_event` like upstream `Framed` keeps its header.
    pending: Option<Pending>,
}

/// A payload-bearing message read before its payload.
enum Pending {
    Frame {
        header: VideoFrameHeader,
        main: Option<Bytes>,
    },
    Cursor {
        id: u32,
        width: u32,
        height: u32,
        hot_x: i32,
        hot_y: i32,
        argb_len: u32,
    },
    Clipboard(ClipboardMsg),
}

impl<S: AsyncRead + Unpin> ServerReader<S> {
    pub fn new(stream: S, support: DecoderSupport) -> Self {
        Self {
            framed: Framed::new(stream),
            tracker: StreamTracker::new(support),
            acked_hello: false,
            pending: None,
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
    ///
    /// Cancel-safe: a caller may race this in a `select!`. A message whose
    /// payload was partly read is resumed by the next call, so a frame is
    /// never lost between its header and its payload.
    pub async fn next_event(&mut self) -> Result<ServerEvent, SessionError> {
        if self.pending.is_none() {
            if let Some(event) = self.read_message().await? {
                return Ok(event);
            }
        }
        self.finish_pending().await
    }

    /// Read the payloads of the pending message, storing each one as it
    /// completes; `Framed::read_payload` only consumes a complete payload.
    async fn finish_pending(&mut self) -> Result<ServerEvent, SessionError> {
        let event = match &mut self.pending {
            None => unreachable!("called with a pending message"),
            Some(Pending::Frame { header, main }) => {
                if main.is_none() {
                    *main = Some(self.framed.read_payload(header.data_len).await?);
                }
                let aux = match header.aux_len {
                    0 => None,
                    n => Some(self.framed.read_payload(n).await?),
                };
                let Some(Pending::Frame { header, main }) = self.pending.take() else {
                    unreachable!()
                };
                let main = main.expect("read above");
                ServerEvent::Frame(self.tracker.on_frame(header, main, aux)?)
            }
            Some(Pending::Cursor {
                id,
                width,
                height,
                hot_x,
                hot_y,
                argb_len,
            }) => {
                let argb = self.framed.read_payload(*argb_len).await?;
                let event = ServerEvent::CursorShape {
                    id: *id,
                    width: *width,
                    height: *height,
                    hot_x: *hot_x,
                    hot_y: *hot_y,
                    argb: Some(argb),
                };
                self.pending = None;
                event
            }
            Some(Pending::Clipboard(ClipboardMsg::Data { data_len, .. })) => {
                let data = self.framed.read_payload(*data_len).await?;
                let Some(Pending::Clipboard(msg)) = self.pending.take() else {
                    unreachable!()
                };
                ServerEvent::Clipboard {
                    msg,
                    data: Some(data),
                }
            }
            Some(Pending::Clipboard(_)) => unreachable!("only Data has a payload"),
        };
        Ok(event)
    }

    /// Read one message. Messages without a payload become an event at
    /// once; the others are left in `pending` for [`Self::finish_pending`].
    async fn read_message(&mut self) -> Result<Option<ServerEvent>, SessionError> {
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
                _ => return Ok(Some(ServerEvent::Error { code, message })),
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
            return Ok(Some(ServerEvent::HelloAck {
                session,
                outputs,
                features,
            }));
        }
        let msg = match msg.into_clipboard() {
            Ok(msg @ ClipboardMsg::Data { .. }) => {
                self.pending = Some(Pending::Clipboard(msg));
                return Ok(None);
            }
            Ok(msg) => return Ok(Some(ServerEvent::Clipboard { msg, data: None })),
            Err(other) => other,
        };
        Ok(Some(match msg {
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
                self.pending = Some(Pending::Frame { header, main: None });
                return Ok(None);
            }
            ServerMsg::CursorShape {
                id,
                width,
                height,
                hot_x,
                hot_y,
                argb_len,
            } if cursor_payload_fits(width, height, argb_len) => {
                self.pending = Some(Pending::Cursor {
                    id,
                    width,
                    height,
                    hot_x,
                    hot_y,
                    argb_len,
                });
                return Ok(None);
            }
            ServerMsg::CursorShape {
                id,
                width,
                height,
                hot_x,
                hot_y,
                ..
            } => ServerEvent::CursorShape {
                id,
                width,
                height,
                hot_x,
                hot_y,
                argb: None,
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
        }))
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
