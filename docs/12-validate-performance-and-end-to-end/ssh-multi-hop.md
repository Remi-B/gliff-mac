# SSH multi-hop implementation and live validation

Status: planned. Owned by [task 12](README.md), before task 13's release gate.
Prerequisites: [task 05](../05-implement-ssh-session/README.md)'s transport,
[task 06](../06-create-native-macos-app/README.md)'s app and
[task 10](../10-implement-displays-and-reconnection/README.md)'s lifecycle handling.

## Outcome

Validate the native app through real OpenSSH ProxyJump routes and implement any
missing behavior or corrections needed to preserve upstream Gliff compatibility.
Task 05's direct SSH sessions, effective-config tests and mock process helpers do
not establish live multi-hop support. This task remains open until runtime
evidence is recorded.

## Work

- [ ] Establish reproducible routes through one bastion and through at least two
  successive bastions, with an unmodified Gliff server at the destination. Use
  controlled SSH endpoints and a headless display with synthetic content.
- [ ] Connect through SSH config aliases with distinct hostnames, users, ports
  and identities per hop. Exercise key-file and GUI-agent authentication from a
  Finder-launched app using the normal SSH configuration.
- [ ] Verify strict known-host checks and noninteractive authentication on every
  hop. Unknown/changed host keys, rejected keys and unavailable agents must give
  actionable errors without relaxing verification or logging credentials.
- [ ] Test an unreachable/stalled bastion, cancellation during each hop's startup,
  link loss while streaming, reconnect, manual disconnect and app quit. Confirm
  bounded deadlines and removal of local SSH/proxy processes, workers, callbacks
  and server-side headless outputs.
- [ ] Verify real frame delivery, pong/ack pacing, native decode and presentation
  through the route; include a resize and a repeated connect/stop sequence.
- [ ] Implement confirmed missing behavior in transport, connection UI or lifecycle
  handling, retain the structured command/security boundaries, and add a regression
  for each defect before rerunning the affected live routes.

## Deliverables and acceptance

- A repeatable recipe or harness documents route topology, exact client/server/
  OpenSSH versions and dated results, without publishing keys or desktop contents.
- One-bastion and multi-bastion routes both render real remote video in the native
  app, maintain feedback, and pass failure/teardown checks without orphaned work.
- Deterministic regressions run in CI; live routes are included in task 12's
  compatibility report and rerun for SSH-related upstream or adapter changes.
- Missing endpoints or hardware are recorded as unavailable and keep this task
  open. Do not mark it passed based on configuration inspection or simulated acks.
