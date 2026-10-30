# 13 — package-and-release-macos

Status: planned. Dependencies: [12](../12-validate-performance-and-end-to-end/README.md).

## Outcome

Distribute a reproducible native macOS app with tested architecture support,
clear server compatibility, signing/notarization and an upstream update path.

## Work

- [ ] Build the release Rust/Swift artifacts for both supported architectures and
  verify the final `.app` executable and embedded bridge architecture coverage.
  Package a universal app, validating deployment target and native library linkage.
- [ ] Configure app-owned version/build numbers, bundle identifier, icons, license/
  third-party notices and provenance for app SHA, upstream SHA, locks and toolchains.
  Preserve upstream attribution and document any temporary patch divergence.
- [ ] Finalize direct-distribution signing, hardened runtime, required entitlements,
  notarization/stapling and `.dmg` or archive packaging. Keep credentials in the
  release environment's private secret mechanism, never repository/config/chat.
- [ ] Validate system SSH, config/keys/agent behavior, known-host errors and native
  resources in the signed Finder-launched app. Do not assume a development terminal
  launch proves release authentication or permission behavior.
- [ ] Add release CI using committed inputs and task 12's gates. Keep developer
  unsigned builds available without distribution credentials. Do not reuse the
  inherited Linux release workflow or publish moving-upstream artifacts.
- [ ] Document installation, supported macOS/hardware, tested server versions,
  authentication setup, keyboard/capture limits, clipboard trust and troubleshooting.
  Explain how to obtain/update the unmodified Linux server independently.
- [ ] Define release rollback and future app update policy; automatic updates and
  Mac App Store distribution require separately scoped work if desired.

## Deliverables and acceptance

- A fresh machine/account can install and launch the signed/notarized app and
  connect without terminal-only environment dependencies. Verify on both hardware
  architectures promised by the release.
- Gatekeeper/signature/notarization checks pass; bundled resources and linkage are
  correct. No unused incoming-network or broad permission entitlement is added.
- The release includes checksums, upstream provenance, compatibility evidence and
  notices. The same locked source inputs reproduce functional unsigned artifacts;
  signing timestamps need not be byte-identical.
- A staged release and rollback are exercised before public publication. This
  planning task does not itself publish releases or create external repositories.

From task 06: the app declares `NSLocalNetworkUsageDescription`. A
Finder-launched app needs the Local Network grant for LAN servers, which
Terminal launches hide. The debug-only `GliffDebugAutoConnect` hook must stay
out of Release builds.
