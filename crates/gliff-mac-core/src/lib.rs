//! App-owned UniFFI facade. Native video, input and UI remain in Swift/AppKit.
//!
//! Swift sees only the records, enums and objects declared here, never the
//! upstream wire types. See `docs/04-build-rust-swift-bridge/bridge-contract.md`
//! for thread ownership, delivery order, budgets and teardown.

mod monitors;
mod session;
mod ssh;
mod types;

pub use monitors::{
    CheckUnavailable, HostMonitors, OrphanCheck, OrphanRemoval, OrphanedOutput, OutputRemoval,
    RemovalOutcome,
};
pub use session::{GliffSession, SessionDelegate};
pub use types::*;

uniffi::setup_scaffolding!();

/// Source provenance exposed without leaking upstream wire types into Swift.
#[derive(uniffi::Record)]
pub struct BuildInfo {
    pub app_version: String,
    pub upstream_revision: String,
    pub protocol_version: u16,
}

#[uniffi::export]
pub fn build_info() -> BuildInfo {
    BuildInfo {
        app_version: env!("CARGO_PKG_VERSION").to_owned(),
        upstream_revision: gliff_client_core::upstream_revision().to_owned(),
        protocol_version: gliff_client_core::protocol_version(),
    }
}
