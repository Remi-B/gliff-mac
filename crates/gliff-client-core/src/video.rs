//! Provisional session/video contract between the wire and the native decoder.
//!
//! The wire has no configuration generation: each `StreamConfig` replaces
//! the previous one, and every `VideoFrame` after it belongs to it. As in
//! upstream `Config::update`, only a change of coded size or chroma mode
//! needs a new decoder; an fps-cap or view/scale change is applied to the
//! following frames without one. The tracker numbers both, so frames can
//! cross the FFI with the decoder generation and configuration revision they
//! belong to, and checks what the native decoder relies on: a supported codec
//! and chroma mode, main/aux association, and a decodable keyframe (in-band
//! SPS/PPS) before any predicted frame of a new decoder generation.
//!
//! Adapted from the stream handling in upstream `crates/gliff/src/net.rs`
//! (`Config`, `validate_stream_size`, `validate_view_size`), without its
//! decoding, GTK or Hyprland parts.

use bytes::Bytes;
use gliff_proto::{ChromaMode, Codec, Rect, VideoPipeline};

use crate::annexb::{self, AnnexBError};

/// Codecs and chroma modes this client implements. An enum value existing
/// upstream is not support: only what is listed here is advertised.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DecoderSupport {
    pub codecs: Vec<Codec>,
    /// Preferred first, as `ClientCaps::chroma`.
    pub chroma: Vec<ChromaMode>,
}

impl DecoderSupport {
    /// What the native client can decode once tasks 07 and 08 land.
    pub fn h264(chroma: &[ChromaMode]) -> Self {
        Self {
            codecs: vec![Codec::H264],
            chroma: chroma.to_vec(),
        }
    }
}

/// Largest stream or view the client accepts, as upstream `MAX_DECODE`.
pub const MAX_DECODE: (u32, u32) = (4096, 4096);

/// One `StreamConfig`, numbered by arrival.
#[derive(Debug, Clone, PartialEq)]
pub struct VideoConfig {
    /// Decoder generation: 1 for the session's first configuration, then +1
    /// whenever the coded size or chroma mode changes.
    pub generation: u32,
    /// 1 for the first configuration, then +1 per `StreamConfig`.
    pub revision: u32,
    /// Whether this configuration needs a new decoder (first, or coded
    /// stream changed). False for a pace-only or view/scale-only update.
    pub rebuild: bool,
    pub codec: Codec,
    pub chroma: ChromaMode,
    pub pipeline: Option<VideoPipeline>,
    /// Coded stream size in physical pixels.
    pub width: u32,
    pub height: u32,
    /// Box the stream is stretched to before fitting it to the window.
    pub view_width: u32,
    pub view_height: u32,
    /// Stream pixels per logical remote pixel, x1000.
    pub scale_milli: u32,
    pub fps_cap: u32,
}

impl VideoConfig {
    fn coded_stream(&self) -> (u32, u32, ChromaMode) {
        (self.width, self.height, self.chroma)
    }

    /// Whether frames of this configuration carry an auxiliary stream.
    pub fn is_dual(&self) -> bool {
        self.chroma == ChromaMode::Dual420
    }

    /// The remote's logical size, the space pointer coordinates use.
    pub fn logical_size(&self) -> (f64, f64) {
        let scale = f64::from(self.scale_milli.max(1)) / 1000.0;
        (
            f64::from(self.width) / scale,
            f64::from(self.height) / scale,
        )
    }
}

/// One encoded access unit (or main/aux pair) ready for the native decoder.
#[derive(Debug, Clone, PartialEq)]
pub struct EncodedFrame {
    pub generation: u32,
    /// The configuration revision in force: its view and scale apply.
    pub revision: u32,
    pub frame_id: u64,
    /// Server wall-clock capture time, microseconds. Not a presentation
    /// clock: the client keeps its own presentation timing.
    pub pts_us: u64,
    pub keyframe: bool,
    pub damage: Vec<Rect>,
    /// Annex B H.264. On a keyframe it starts with SPS and PPS.
    pub main: Bytes,
    /// The auxiliary chroma stream, present iff the configuration is `Dual420`.
    pub aux: Option<Bytes>,
}

/// What the client does with a frame the tracker accepted. Every accepted
/// frame is acknowledged with `FrameAck` once handled, decoded or not:
/// upstream acks even a failed decode, and the server's rate control counts
/// unacknowledged bytes in flight, so a missing ack stalls the stream.
#[derive(Debug, Clone, PartialEq)]
pub enum FrameDisposition {
    /// Hand to the native decoder; ack when it reports completion.
    Decode(EncodedFrame),
    /// The decoder has no usable reference yet (no keyframe since the last
    /// rebuild or recovery). The frame is dropped and acked at once; one
    /// `RequestKeyframe` is sent; later frames are dropped silently until a
    /// keyframe arrives.
    AwaitKeyframe {
        frame_id: u64,
        request_keyframe: bool,
    },
}

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum ContractError {
    #[error("the server chose codec {0:?}, which this client never advertised")]
    UnsupportedCodec(Codec),
    #[error("the server chose chroma mode {0:?}, which this client never advertised")]
    UnsupportedChroma(ChromaMode),
    #[error("stream size {width}x{height} is empty, odd or above 4096x4096")]
    InvalidSize { width: u32, height: u32 },
    #[error("view {view_width}x{view_height} is invalid for a {width}x{height} stream")]
    InvalidView {
        view_width: u32,
        view_height: u32,
        width: u32,
        height: u32,
    },
    #[error("video frame {0} arrived before any stream configuration")]
    FrameBeforeConfig(u64),
    #[error("video frame {frame_id} declares aux_len {aux_len} for chroma mode {chroma:?}")]
    AuxMismatch {
        frame_id: u64,
        chroma: ChromaMode,
        aux_len: u32,
    },
    #[error("video frame {frame_id} has no main stream bytes")]
    EmptyFrame { frame_id: u64 },
    #[error("frame id {frame_id} does not follow {previous}")]
    FrameIdNotIncreasing { previous: u64, frame_id: u64 },
    #[error("keyframe {frame_id} lacks in-band SPS/PPS before its IDR in the {stream} stream")]
    KeyframeNotSelfContained { frame_id: u64, stream: &'static str },
    #[error("frame {frame_id}, {stream} stream: {source}")]
    NotAnnexB {
        frame_id: u64,
        stream: &'static str,
        source: AnnexBError,
    },
}

/// Numbers configurations and validates frames against the current one.
#[derive(Debug)]
pub struct StreamTracker {
    support: DecoderSupport,
    config: Option<VideoConfig>,
    generations: u32,
    revisions: u32,
    last_frame_id: Option<u64>,
    /// No decodable reference: set by a configuration, cleared by a keyframe.
    needs_keyframe: bool,
    keyframe_requested: bool,
}

/// The `StreamConfig` fields the tracker reads, so callers can pass a
/// decoded `ServerMsg` without the tracker owning wire types.
#[derive(Debug, Clone)]
pub struct StreamConfigFields<'a> {
    pub codec: Codec,
    pub chroma: ChromaMode,
    pub pipeline: Option<VideoPipeline>,
    pub width: u32,
    pub height: u32,
    pub scale_milli: u32,
    /// Ignored: kept so callers pass the whole message and drift is visible.
    pub extradata: &'a [u8],
    pub aux_extradata: Option<&'a [u8]>,
    pub view_width: u32,
    pub view_height: u32,
    pub fps_cap: u32,
}

/// The `VideoFrame` header fields.
#[derive(Debug, Clone)]
pub struct VideoFrameHeader {
    pub frame_id: u64,
    pub pts_us: u64,
    pub keyframe: bool,
    pub damage: Vec<Rect>,
    pub data_len: u32,
    pub aux_len: u32,
}

impl StreamTracker {
    pub fn new(support: DecoderSupport) -> Self {
        Self {
            support,
            config: None,
            generations: 0,
            revisions: 0,
            last_frame_id: None,
            needs_keyframe: true,
            keyframe_requested: false,
        }
    }

    pub fn support(&self) -> &DecoderSupport {
        &self.support
    }

    pub fn config(&self) -> Option<&VideoConfig> {
        self.config.as_ref()
    }

    /// Accept a configuration. On a rebuild, frames still queued for the
    /// previous generation must be discarded by the caller and the next
    /// decodable frame is a keyframe. `extradata` is ignored, as upstream
    /// does: parameter sets travel in-band and keyframes are checked for them.
    pub fn on_config(&mut self, c: StreamConfigFields<'_>) -> Result<&VideoConfig, ContractError> {
        if !self.support.codecs.contains(&c.codec) {
            return Err(ContractError::UnsupportedCodec(c.codec));
        }
        if !self.support.chroma.contains(&c.chroma) {
            return Err(ContractError::UnsupportedChroma(c.chroma));
        }
        let (max_w, max_h) = MAX_DECODE;
        if c.width == 0
            || c.height == 0
            || c.width > max_w
            || c.height > max_h
            || !c.width.is_multiple_of(2)
            || !c.height.is_multiple_of(2)
        {
            return Err(ContractError::InvalidSize {
                width: c.width,
                height: c.height,
            });
        }
        // As upstream `validate_view_size`: never more than twice smaller
        // than the stream, which would drive the integer zoom to hundreds.
        if c.view_width == 0
            || c.view_height == 0
            || c.view_width > max_w
            || c.view_height > max_h
            || u64::from(c.view_width) * 2 < u64::from(c.width)
            || u64::from(c.view_height) * 2 < u64::from(c.height)
        {
            return Err(ContractError::InvalidView {
                view_width: c.view_width,
                view_height: c.view_height,
                width: c.width,
                height: c.height,
            });
        }
        let rebuild = self
            .config
            .as_ref()
            .is_none_or(|old| old.coded_stream() != (c.width, c.height, c.chroma));
        if rebuild {
            self.generations += 1;
            self.needs_keyframe = true;
            self.keyframe_requested = false;
        }
        self.revisions += 1;
        Ok(self.config.insert(VideoConfig {
            generation: self.generations,
            revision: self.revisions,
            rebuild,
            codec: c.codec,
            chroma: c.chroma,
            pipeline: c.pipeline,
            width: c.width,
            height: c.height,
            view_width: c.view_width,
            view_height: c.view_height,
            scale_milli: c.scale_milli,
            fps_cap: c.fps_cap,
        }))
    }

    /// Check that a frame header fits the current configuration, before its
    /// payload is read.
    pub fn check_header(&self, h: &VideoFrameHeader) -> Result<&VideoConfig, ContractError> {
        let config = self
            .config
            .as_ref()
            .ok_or(ContractError::FrameBeforeConfig(h.frame_id))?;
        if config.is_dual() != (h.aux_len > 0) {
            return Err(ContractError::AuxMismatch {
                frame_id: h.frame_id,
                chroma: config.chroma,
                aux_len: h.aux_len,
            });
        }
        if h.data_len == 0 {
            return Err(ContractError::EmptyFrame {
                frame_id: h.frame_id,
            });
        }
        if let Some(previous) = self.last_frame_id {
            if h.frame_id <= previous {
                return Err(ContractError::FrameIdNotIncreasing {
                    previous,
                    frame_id: h.frame_id,
                });
            }
        }
        Ok(config)
    }

    /// Accept a frame and its payloads, read in wire order (main, then aux).
    pub fn on_frame(
        &mut self,
        h: VideoFrameHeader,
        main: Bytes,
        aux: Option<Bytes>,
    ) -> Result<FrameDisposition, ContractError> {
        let config = self.check_header(&h)?;
        let (generation, revision) = (config.generation, config.revision);
        self.last_frame_id = Some(h.frame_id);
        let streams = [("main", Some(&main)), ("aux", aux.as_ref())];
        for (stream, bytes) in streams {
            let Some(bytes) = bytes else { continue };
            let not_annex_b = |source| ContractError::NotAnnexB {
                frame_id: h.frame_id,
                stream,
                source,
            };
            annexb::nal_units(bytes).map_err(not_annex_b)?;
            if h.keyframe && !annexb::is_self_contained_idr(bytes).map_err(not_annex_b)? {
                return Err(ContractError::KeyframeNotSelfContained {
                    frame_id: h.frame_id,
                    stream,
                });
            }
        }
        if h.keyframe {
            self.needs_keyframe = false;
            self.keyframe_requested = false;
        }
        if self.needs_keyframe {
            let request_keyframe = !std::mem::replace(&mut self.keyframe_requested, true);
            return Ok(FrameDisposition::AwaitKeyframe {
                frame_id: h.frame_id,
                request_keyframe,
            });
        }
        Ok(FrameDisposition::Decode(EncodedFrame {
            generation,
            revision,
            frame_id: h.frame_id,
            pts_us: h.pts_us,
            keyframe: h.keyframe,
            damage: h.damage,
            main,
            aux,
        }))
    }

    /// The native decoder failed or encoded data had to be abandoned: drop
    /// predicted frames until the next keyframe, which is requested once.
    pub fn lose_reference(&mut self) -> bool {
        self.needs_keyframe = true;
        !std::mem::replace(&mut self.keyframe_requested, true)
    }
}
