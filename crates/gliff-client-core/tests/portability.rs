//! Upstream behaviours that differ on macOS. Each test pins the current
//! behaviour so an upstream change is noticed; see
//! `docs/02-audit-upstream-protocol-and-portability/portability-audit.md`.

/// `gliff_transport::clipboard::files::Spool::create_in` sweeps spool
/// directories named `<pid>-<n>` whose process is gone, testing liveness
/// with `/proc/<pid>`. macOS has no `/proc`, so every other process counts
/// as dead and the spool of a live process is deleted. Task 11 must give
/// each app process its own spool base (or use an upstream fix).
#[cfg(target_os = "macos")]
#[test]
fn upstream_spool_sweep_deletes_a_live_process_spool_on_macos() {
    let base = std::env::temp_dir().join(format!("gliff-spool-audit-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&base);
    // launchd (pid 1) is always alive.
    let live = base.join("1-0");
    std::fs::create_dir_all(&live).unwrap();
    let spool = gliff_transport::clipboard::files::Spool::create_in(&base).unwrap();
    let deleted = !live.exists();
    drop(spool);
    let _ = std::fs::remove_dir_all(&base);
    assert!(
        deleted,
        "upstream now keeps live spools on macOS: update the portability audit and task 11"
    );
}
