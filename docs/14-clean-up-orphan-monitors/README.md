# 14 — clean-up-orphan-monitors

Status: in review; implemented with bridge, script and app tests and live checks on
the Omarchy host (see the [implementation record](implementation-record.md)). A host
without Hyprland is verified by tests only. Dependencies: [10](../10-implement-displays-and-reconnection/README.md).
Scheduled before task 11: orphaned outputs disturb every development session until
the server side is fixed.

## Outcome

Detect the virtual monitors that dead Gliff servers left on the host and remove them
after the user confirms, so a crash, a forced kill or a monitor tool reconfiguring
the displays no longer leaves invisible monitors behind. Later, a setting removes
them without asking.

## Background

In virtual display mode the unmodified server creates a headless output named
`gliff-<pid>` (its own process id) and removes it when it exits; it ignores the
result of that removal. Two ways to leave an orphan are known:

- A server killed with SIGKILL never runs its cleanup (task 10 finding).
- 2026-10-31 on the Omarchy host: during a session, the user switched displays in
  Omarchy's monitor panel. Its daemon (`hyprmoncfgd`) disabled the virtual output and
  re-enabled it a second later. The server lost its output and exited; its removal
  did not stick, and the output came back with no server. The app reconnected as
  designed with a new output, which was later removed normally; the old one stayed.

An orphan is still a monitor for Hyprland: workspaces and windows can end up on it,
out of sight, until it is removed by hand (`hyprctl output remove gliff-<pid>`) or
Hyprland restarts. Until this task lands, the Omarchy host has interim helpers
outside the repository: `~/Projects/Gliff/utils/list-monitors.sh` and
`cleanup-monitors.sh`.

## Rules

- An output is an orphan when its name matches `^gliff-[0-9]+$` and no running
  process with that pid is a `gliff-server` (checked through `/proc/<pid>/cmdline`,
  so a reused pid is not mistaken for the server). Disabled outputs count.
- Physical monitors, outputs with other names and outputs of running servers are
  never removed, whichever client or session owns them. Other Unix users have their
  own Hyprland instance, which the check cannot see.
- Removal re-checks each output immediately before removing it and skips any whose
  server is running again.
- Known limit: a server running in another pid namespace (container, Flatpak) looks
  orphaned. This is why confirmation is the default and the automatic setting is off.

## Work

- [x] Remote check in the bridge, over a separate SSH command with the session's
  policy (same host, user, identity, known hosts, batch mode): a fixed POSIX `sh`
  script with no user input interpolated, which finds the Hyprland instance when the
  environment does not name it, lists orphaned `gliff-<pid>` outputs with size and
  enabled state, and prints a strict line format. A host without `hyprctl` or a
  running Hyprland returns no orphans and logs the reason, without an error for the
  user. Time-bounded and cancelled with its window or session.
- [x] Removal in the bridge for a given list of names, with the re-check above;
  returns a result per output (removed, still in use, failed).
- [x] Run the check after every successful connection, including automatic
  reconnections and mirror mode, without delaying the session.
- [x] Confirmation sheet on the session window: host, count, names and sizes, and a
  note that windows on these monitors move to another monitor. **Remove** and
  **Ignore**; ignored outputs are not offered again for that window. Show the result.
- [x] Setting "Automatically remove orphaned virtual monitors", off by default: when
  on, remove without the sheet and show a short status instead.
- [x] Logs: counts, outcomes and output names only; no host names or paths.
- [x] Verify on the live host what Hyprland does with windows and workspaces of a
  removed headless output (expected: moved to a remaining monitor, nothing closed),
  using only temporary headless outputs, never capturing the physical monitor.
  Record it and adjust the sheet's wording.
- [x] Propose the server-side fix upstream separately (verify or retry the removal,
  survive a disabled/re-enabled output, remove its own stale outputs at startup);
  the app keeps no patch to the vendored server. Drafted in
  [upstream-proposal.md](upstream-proposal.md); filing it upstream is the user's call.

## Deliverables and acceptance

- Unit tests: parsing of the check's output, malformed or hostile lines rejected,
  classification, re-check before removal, ignored outputs, automatic setting,
  cancellation with the session.
- Live on the Omarchy host with the unmodified server: an orphan left by a killed
  server is offered after the automatic reconnection and removed on confirmation;
  the output of another running session is never offered nor removed; Ignore does
  not ask again; the automatic setting removes without asking; a host without
  Hyprland shows nothing; no output, server or local SSH process is left over.
- The check is covered by a required gate (extend `displays-reconnect` or add one).
