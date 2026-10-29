//! Platform-independent integration boundary for the native Gliff client.
//!
//! Upstream owns wire types, framing, SSH transport and clipboard transfers.
//! This crate adds the client-side contract the native app depends on: the
//! handshake and payload association of server messages, the video stream
//! rules checked before frames reach the native decoder, and a
//! transport-independent session driver. It does not decode video or depend
//! on the upstream Linux client binary.

pub mod annexb;
pub mod events;
pub mod session;
pub mod video;

/// The wire version supplied by the pinned upstream protocol crate.
pub fn protocol_version() -> u16 {
    gliff_proto::PROTOCOL_VERSION
}

/// The upstream source revision used by this application build.
pub fn upstream_revision() -> &'static str {
    include_str!("../../../upstream-revision").trim()
}
