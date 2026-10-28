# 11 — implement-shared-clipboard

Status: planned. Dependencies: [05](../05-implement-ssh-session/README.md),
[06](../06-create-native-macos-app/README.md),
[10](../10-implement-displays-and-reconnection/README.md).

## Outcome

Integrate NSPasteboard with upstream's existing on-demand transfer engine for
bidirectional text, images and copied files. Preserve session ownership and cancel
obsolete transfers instead of inventing a second clipboard protocol.

## Work

- [ ] Adapt NSPasteboard types and change counts to upstream MIME offers/serials.
  Reuse `gliff-transport` transfer flow control, acknowledgments, limits and file
  spool rules. Expose app-owned callback/command records across UniFFI.
- [ ] Implement on-demand text first, then images and copied files/directories with
  lazy providers/file promises where supported. Specify MIME/UTI conversion,
  file-URL semantics and behavior when another application requests data.
- [ ] Forward only the active session's local clipboard offer and permit remote
  offers to take ownership only for that session. Withdraw/revoke offers on copy,
  switch, disconnect and capture-policy changes. Prevent copy echo loops.
- [ ] Implement sharing opt-out, sensitive pasteboard-type filtering, clear trust
  behavior and cancellation. Advertised content can be requested by the connected
  host without an explicit local paste; reflect upstream's trust model in settings.
- [ ] Validate paths and metadata before file materialization; handle traversal,
  collisions, symlinks, size/disk limits and cleanup using the existing transfer
  engine plus native checks. Use the app cache location, not hard-coded Linux paths.
- [ ] Add progress/cancel UI for long transfers and bounded background I/O. Do not
  block the main actor or permit clipboard traffic to starve control/frame feedback.
- [ ] On reconnect, begin fresh offers and serial ownership; abort pending reads
  and remove obsolete providers safely. Never serve data for a revoked selection.

## Deliverables and acceptance

- macOS ↔ Linux tests cover Unicode text, image formats, binary payloads, empty
  files, directories, Unicode names, cancellation and interrupted/replaced selections.
- A stale/inactive session cannot read clipboard content; opt-out sends no offers
  or clipboard bodies. Sensitive selections remain excluded.
- Malformed file metadata cannot escape the cache destination or exhaust configured
  budgets. Disk-full/provider failure produces a useful error and cleanup.
- Progress/cancel and reconnect tests leave no pending pasteboard callbacks,
  incomplete transfer workers or unexpected retained file data.
