//! Records, enums and errors crossing the FFI, and their conversions from
//! `gliff-client-core`. Buffers cross as `Vec<u8>` (Swift `Data`, one copy).

use gliff_client_core::events::SessionError;
use gliff_client_core::session::{self as core, ControlError};
use gliff_client_core::video;
use gliff_proto::VideoPipeline;

/// Where the session's server stream comes from.
#[derive(Debug, Clone, uniffi::Enum)]
pub enum ConnectionTarget {
    /// `gliff-server --stdio` over the system OpenSSH client (task 05).
    Ssh {
        /// Host name, address or ssh config alias.
        host: String,
        user: Option<String>,
        port: Option<u16>,
        /// Remote server path; `gliff-server` on PATH by default.
        server_path: Option<String>,
        identity_file: Option<String>,
        headless: bool,
        video_mode: VideoMode,
    },
    /// A recorded server-to-client stream (a `.gliffstream` fixture). Client
    /// messages are counted, not sent. For tests and diagnostics.
    Replay { stream: Vec<u8> },
}

/// The server's `--video` choice. A closed enum: the remote command is built
/// from these fixed spellings, never from caller text.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, uniffi::Enum)]
pub enum VideoMode {
    /// The server chooses from `GLIFF_VIDEO`, else GPU with CPU fallback.
    #[default]
    Auto,
    /// `--video cpu`
    Cpu,
    /// `--video gpu`
    Gpu,
}

impl VideoMode {
    /// Preserve Auto's prior behavior by omitting `--video`; the bundled
    /// server also accepts explicit `--video auto` for other callers.
    pub(crate) fn flag(self) -> Option<&'static str> {
        match self {
            Self::Auto => None,
            Self::Cpu => Some("cpu"),
            Self::Gpu => Some("gpu"),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum ChromaMode {
    Single420,
    Dual420,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct SessionOptions {
    /// What the native decoder implements, preferred first. Advertised to
    /// the server as is.
    pub chroma: Vec<ChromaMode>,
    /// XKB keymap text, or empty for the server's default (US) map.
    #[uniffi(default = "")]
    pub keymap: String,
    /// Frames handed to Swift and not yet reported.
    #[uniffi(default = 4)]
    pub max_in_flight_frames: u32,
    /// Byte budget floor for those frames; grows to twice the largest
    /// keyframe.
    #[uniffi(default = 8388608)]
    pub min_in_flight_bytes: u64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum Pipeline {
    Cpu,
    Gpu,
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct OutputInfo {
    pub name: String,
    pub width: u32,
    pub height: u32,
    pub scale_milli: u32,
}

/// The server's `HelloAck`.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct ServerHello {
    pub headless: bool,
    pub output: String,
    pub outputs: Vec<OutputInfo>,
    pub features: Vec<String>,
}

/// One stream configuration; see the session contract.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct VideoConfig {
    pub generation: u32,
    pub revision: u32,
    /// Replace the decoder session: a new generation starts here.
    pub rebuild: bool,
    pub chroma: ChromaMode,
    pub pipeline: Option<Pipeline>,
    pub width: u32,
    pub height: u32,
    pub view_width: u32,
    pub view_height: u32,
    pub scale_milli: u32,
    pub fps_cap: u32,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Record)]
pub struct DamageRect {
    pub x: i32,
    pub y: i32,
    pub width: i32,
    pub height: i32,
}

/// One access unit (Single420) or main/aux pair (Dual420), Annex B.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct EncodedFrame {
    pub generation: u32,
    pub revision: u32,
    pub frame_id: u64,
    pub pts_us: u64,
    pub keyframe: bool,
    pub damage: Vec<DamageRect>,
    pub main: Vec<u8>,
    pub aux: Option<Vec<u8>>,
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct CursorShape {
    pub id: u32,
    pub width: u32,
    pub height: u32,
    pub hot_x: i32,
    pub hot_y: i32,
    /// Premultiplied ARGB words; `None` for a malformed shape.
    pub argb: Option<Vec<u8>>,
}

#[derive(Debug, Clone, Copy, PartialEq, uniffi::Record)]
pub struct CursorPosition {
    pub x: f64,
    pub y: f64,
    pub shape_id: u32,
    pub visible: bool,
}

/// What became of a frame delivered to `SessionDelegate::on_frame`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum DecodeOutcome {
    Decoded,
    /// Loses the decoder reference: a keyframe is requested.
    Failed,
    /// Not decoded, for example after the decoder session was replaced.
    Discarded,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum ScrollAxis {
    Vertical,
    Horizontal,
}

/// Input for the remote. Coordinates are in the remote's logical space;
/// key codes are Linux evdev codes (task 09 maps macOS keys).
#[derive(Debug, Clone, Copy, PartialEq, uniffi::Enum)]
pub enum InputEvent {
    Key {
        keycode: u32,
        pressed: bool,
    },
    PointerMotion {
        x: f64,
        y: f64,
    },
    PointerButton {
        button: u32,
        pressed: bool,
    },
    Scroll {
        axis: ScrollAxis,
        value: f64,
        discrete: Option<i32>,
        stop: bool,
    },
    Resize {
        width: u32,
        height: u32,
        scale: f32,
    },
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, uniffi::Record)]
pub struct SessionStats {
    pub configs: u64,
    pub frames_delivered: u64,
    pub frames_dropped: u64,
    pub frames_failed: u64,
    pub acks_sent: u64,
    pub keyframe_requests: u64,
    pub pongs_sent: u64,
    pub inputs_sent: u64,
    pub peak_in_flight_frames: u64,
    pub peak_in_flight_bytes: u64,
}

/// How a session ended. Delivered once, as the last callback.
#[derive(Debug, Clone, PartialEq, uniffi::Enum)]
pub enum SessionEnd {
    /// The server closed the stream.
    Closed,
    Cancelled,
    Failed {
        error: GliffError,
    },
}

#[derive(Debug, Clone, PartialEq, thiserror::Error, uniffi::Error)]
pub enum GliffError {
    #[error("invalid options: {message}")]
    InvalidOptions { message: String },
    #[error("not supported yet: {message}")]
    Unsupported { message: String },
    #[error("the session was already started")]
    AlreadyStarted,
    #[error("the session is not running")]
    NotRunning,
    #[error("the input queue is full")]
    Busy,
    #[error("frame {frame_id} is not awaiting a decode report")]
    UnknownFrame { frame_id: u64 },
    #[error("connection: {message}")]
    Transport { message: String },
    /// The server broke the session/video contract. Not retryable.
    #[error("protocol contract: {message}")]
    Contract { message: String },
    /// Not retryable: one side must be updated.
    #[error("{reason} (client protocol {client}, server protocol {server})")]
    VersionMismatch {
        client: u16,
        server: u16,
        reason: String,
    },
    /// Not retryable (codes 1–255).
    #[error("incompatible server (code {code}): {message}")]
    Incompatible { code: u16, message: String },
    #[error("protocol: {message}")]
    Protocol { message: String },
}

/// Whether reconnecting cannot help after this error.
#[uniffi::export]
pub fn is_fatal_incompatibility(error: &GliffError) -> bool {
    matches!(
        error,
        GliffError::Contract { .. }
            | GliffError::VersionMismatch { .. }
            | GliffError::Incompatible { .. }
    )
}

impl From<SessionError> for GliffError {
    fn from(e: SessionError) -> Self {
        let message = e.to_string();
        match e {
            SessionError::Transport(_) => Self::Transport { message },
            SessionError::Contract(_) => Self::Contract { message },
            SessionError::VersionMismatch {
                client,
                server,
                reason,
            } => Self::VersionMismatch {
                client,
                server,
                reason: reason.to_owned(),
            },
            SessionError::Incompatible { code, message } => Self::Incompatible { code, message },
            SessionError::UnexpectedFirstMessage(_) | SessionError::RepeatedHelloAck => {
                Self::Protocol { message }
            }
        }
    }
}

impl From<ControlError> for GliffError {
    fn from(e: ControlError) -> Self {
        match e {
            ControlError::NotRunning => Self::NotRunning,
            ControlError::Busy => Self::Busy,
            ControlError::UnknownFrame(frame_id) => Self::UnknownFrame { frame_id },
        }
    }
}

fn invalid(message: impl Into<String>) -> GliffError {
    GliffError::InvalidOptions {
        message: message.into(),
    }
}

/// An ssh argument that cannot be mistaken for an option or split.
fn check_word(what: &str, value: &str) -> Result<(), GliffError> {
    if value.is_empty() {
        return Err(invalid(format!("{what} is empty")));
    }
    if value.starts_with('-') {
        return Err(invalid(format!("{what} cannot start with '-'")));
    }
    if value.chars().any(|c| c.is_whitespace() || c.is_control()) {
        return Err(invalid(format!(
            "{what} cannot contain spaces or control characters"
        )));
    }
    Ok(())
}

impl ConnectionTarget {
    pub(crate) fn validate(&self) -> Result<(), GliffError> {
        match self {
            Self::Ssh {
                host,
                user,
                port,
                server_path,
                identity_file,
                ..
            } => {
                check_word("host", host)?;
                if !host
                    .bytes()
                    .all(|b| b.is_ascii_alphanumeric() || b".-_:[]%".contains(&b))
                {
                    return Err(invalid("host must be a hostname, address or config alias"));
                }
                if let Some(path) = identity_file {
                    if !path.starts_with('/') || path.chars().any(char::is_control) {
                        return Err(invalid(
                            "identity file must be an absolute path without control characters",
                        ));
                    }
                }
                if let Some(user) = user {
                    check_word("user", user)?;
                    if !user
                        .bytes()
                        .all(|b| b.is_ascii_alphanumeric() || b"._-".contains(&b))
                    {
                        return Err(invalid(
                            "user must contain only ASCII letters, digits, '.', '_' or '-'",
                        ));
                    }
                }
                if *port == Some(0) {
                    return Err(invalid("port 0 is not a valid ssh port"));
                }
                if let Some(path) = server_path {
                    check_word("server path", path)?;
                    if path.starts_with('~') {
                        return Err(invalid("server path cannot use '~'; use an absolute path or an executable name on the remote PATH"));
                    }
                }
                Ok(())
            }
            Self::Replay { stream } if stream.is_empty() => Err(invalid("replay stream is empty")),
            Self::Replay { .. } => Ok(()),
        }
    }
}

impl SessionOptions {
    pub(crate) fn to_core(&self) -> Result<core::SessionConfig, GliffError> {
        if self.chroma.is_empty() {
            return Err(invalid("at least one chroma mode is required"));
        }
        let mut chroma = Vec::new();
        for mode in &self.chroma {
            let mode = match mode {
                ChromaMode::Single420 => gliff_proto::ChromaMode::Single420,
                ChromaMode::Dual420 => gliff_proto::ChromaMode::Dual420,
            };
            if chroma.contains(&mode) {
                return Err(invalid("chroma modes must not repeat"));
            }
            chroma.push(mode);
        }
        if !(1..=64).contains(&self.max_in_flight_frames) {
            return Err(invalid("max_in_flight_frames must be between 1 and 64"));
        }
        if !((1 << 20)..=(1 << 30)).contains(&self.min_in_flight_bytes) {
            return Err(invalid(
                "min_in_flight_bytes must be between 1 MiB and 1 GiB",
            ));
        }
        Ok(core::SessionConfig {
            support: video::DecoderSupport::h264(&chroma),
            keymap: self.keymap.clone(),
            budget: core::FrameBudget {
                max_frames: self.max_in_flight_frames as usize,
                min_bytes: self.min_in_flight_bytes,
            },
            drain_on_close: false,
        })
    }
}

impl From<video::VideoConfig> for VideoConfig {
    fn from(c: video::VideoConfig) -> Self {
        Self {
            generation: c.generation,
            revision: c.revision,
            rebuild: c.rebuild,
            chroma: match c.chroma {
                gliff_proto::ChromaMode::Dual420 => ChromaMode::Dual420,
                // The tracker rejects anything that was not advertised.
                _ => ChromaMode::Single420,
            },
            pipeline: c.pipeline.map(|p| match p {
                VideoPipeline::Cpu => Pipeline::Cpu,
                VideoPipeline::Gpu => Pipeline::Gpu,
            }),
            width: c.width,
            height: c.height,
            view_width: c.view_width,
            view_height: c.view_height,
            scale_milli: c.scale_milli,
            fps_cap: c.fps_cap,
        }
    }
}

impl From<video::EncodedFrame> for EncodedFrame {
    fn from(f: video::EncodedFrame) -> Self {
        Self {
            generation: f.generation,
            revision: f.revision,
            frame_id: f.frame_id,
            pts_us: f.pts_us,
            keyframe: f.keyframe,
            damage: f
                .damage
                .iter()
                .map(|r| DamageRect {
                    x: r.x,
                    y: r.y,
                    width: r.width,
                    height: r.height,
                })
                .collect(),
            main: f.main.to_vec(),
            aux: f.aux.map(|a| a.to_vec()),
        }
    }
}

impl From<InputEvent> for core::InputCommand {
    fn from(e: InputEvent) -> Self {
        match e {
            InputEvent::Key { keycode, pressed } => Self::Key { keycode, pressed },
            InputEvent::PointerMotion { x, y } => Self::PointerMotion { x, y },
            InputEvent::PointerButton { button, pressed } => {
                Self::PointerButton { button, pressed }
            }
            InputEvent::Scroll {
                axis,
                value,
                discrete,
                stop,
            } => Self::PointerAxis {
                horizontal: axis == ScrollAxis::Horizontal,
                value,
                discrete,
                stop,
            },
            InputEvent::Resize {
                width,
                height,
                scale,
            } => Self::Resize {
                width,
                height,
                scale,
            },
        }
    }
}

impl From<DecodeOutcome> for core::FrameOutcome {
    fn from(o: DecodeOutcome) -> Self {
        match o {
            DecodeOutcome::Decoded => Self::Decoded,
            DecodeOutcome::Failed => Self::Failed,
            DecodeOutcome::Discarded => Self::Discarded,
        }
    }
}

impl From<core::Stats> for SessionStats {
    fn from(s: core::Stats) -> Self {
        Self {
            configs: s.configs,
            frames_delivered: s.frames_delivered,
            frames_dropped: s.frames_dropped,
            frames_failed: s.frames_failed,
            acks_sent: s.acks_sent,
            keyframe_requests: s.keyframe_requests,
            pongs_sent: s.pongs_sent,
            inputs_sent: s.inputs_sent,
            peak_in_flight_frames: s.peak_in_flight_frames,
            peak_in_flight_bytes: s.peak_in_flight_bytes,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum SessionState {
    Connecting,
    Handshaking,
    Streaming,
    Stopping,
    Closed,
    Failed,
}
