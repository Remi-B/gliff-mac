//! Platform-independent integration boundary for the native Gliff client.
//!
//! Upstream owns wire types, framing, SSH transport and clipboard transfers.
//! Session orchestration belongs here in a later task; this scaffold does not
//! connect, decode video, or depend on the upstream Linux client binary.

/// The wire version supplied by the pinned upstream protocol crate.
pub fn protocol_version() -> u16 {
    gliff_proto::PROTOCOL_VERSION
}

/// The upstream source revision used by this application build.
pub fn upstream_revision() -> &'static str {
    include_str!("../../../upstream-revision").trim()
}
