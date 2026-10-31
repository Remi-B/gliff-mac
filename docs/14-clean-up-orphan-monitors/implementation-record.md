# Task 14 implementation record

Updated 2026-10-31. Branch `feat/orphan-monitor-cleanup`, based on merged task 10
`d0373b6`. Upstream stays unmodified at `58c742452ded3f10a2ce61f60eb4845f18205e29`
(Gliff 0.4.1); the server-side fix is a separate [upstream issue draft](../upstream-issues/headless-output-outlives-server.md).

## What an orphan is

An output whose name matches `^gliff-[0-9]+$` (digits, no leading zero, at most 7
digits: `pid_max` is at most 4194304) and whose pid does not run a program named
`gliff-server*`. The name is read from `argv[0]` in `/proc/<pid>/cmdline`, so a pid
reused by another program is not mistaken for the server, and development builds
(`gliff-server-<sha>.bin`) count. The check fails safe: a pid whose `/proc` entry exists
but whose command line cannot be read (`hidepid`, a race) counts as running. Disabled
outputs count. Physical monitors, other
names and outputs of running servers are never listed, whichever client started them.

Known limits: a server in another pid namespace (container, Flatpak) looks orphaned,
which is why the sheet is the default; another Unix user's Hyprland is not seen.

## Bridge

`HostMonitors` (`crates/gliff-mac-core/src/monitors.rs`) is a UniFFI object separate
from `GliffSession`. Each call is its own `/usr/bin/ssh` process with the session's
policy file and options (`ssh::ssh`, shared with the session command): same host,
user, port, identity, known hosts and batch mode, no forwarding, no server options.
The remote command is fixed: `sh -s -- check` or `sh -s -- remove NAME...`, with
validated names only. The script (`orphans.sh`) arrives on stdin, so nothing typed by
the user is interpolated into it, and it runs under any POSIX `sh` whatever the login
shell.

- **Instance:** the environment's `HYPRLAND_INSTANCE_SIGNATURE` when it answers, else
  the newest directory under `$XDG_RUNTIME_DIR/hypr` (default `/run/user/<uid>`) with
  a socket that answers. Without `hyprctl`, an answering instance or a monitor list,
  the check returns `Unavailable` (`noHyprctl`, `noHyprland`, `hyprctlFailed`): no
  orphans and a log line, no error for the user.
- **Listing:** `hyprctl monitors all` (text, so `jq` is not required), parsed with `awk`.
- **Removal:** each name is checked again right before (`in-use` if its server runs),
  and again after enabling a disabled output, since that can take seconds; a disabled
  output is enabled first, because Hyprland answers `output not found` for
  a disabled one (verified live). The Lua `hl.monitor({ ..., disabled = false })` is
  tried, then the hyprlang `monitor NAME,preferred,auto,1` keyword. `hyprctl` replies
  `ok` even when nothing changed, so the script waits up to about 2 seconds for the
  name to disappear and reports `removed` or `failed`; an output already gone is
  `removed`. When Hyprland stops answering, the state is unknown and the result is
  `failed`, never `removed`. Enabling leaves a runtime monitor rule for that `gliff-<pid>` name until
  Hyprland reloads its configuration; it matches nothing once the output is removed.
- **Report:** lines `gliff-orphans 1 ...` between `begin` and `end COUNT`. Lines before
  `begin` (login shell noise) and after `end` are ignored; inside, any malformed line,
  bad name, size, state or count, repetition, result for an unrequested name or more
  than 64 entries rejects the whole report (`Protocol` error). Stdout is capped at
  64 KiB, stderr at 16 KiB and only classified (`ssh::diagnostic`), never returned.
- **Bounds:** 30 seconds for a check, 60 for a removal. `cancel()`, dropping the
  object, dropping a pending call's future, the time limit or completion terminate the SSH process group (TERM, then
  KILL after 200 ms), as for sessions. A closed cancel channel does not cancel (this
  was a bug found by the tests: a dropped sender ended runs as cancelled).

## App

- `OrphanMonitors` (one per window, owned by `SessionController`) starts a check on
  every `HelloAck` (first connection, automatic reconnection, mirror mode) through
  `LiveMonitorService`, in parallel with the session. The check is cancelled when its
  session ends (Swift task cancellation → `HostMonitors.cancel()`), and so is an
  automatic removal; a result from an
  older check is dropped. No new check starts while one runs, an offer waits or a
  removal runs.
- Found outputs minus those ignored in this window go to the sheet: host, count, names,
  sizes and disabled state, the note that their workspaces and windows move to another
  monitor and nothing is closed, **Remove** (default) and **Ignore** (cancel). Remove
  shows progress, then a result per output and a summary. Ignore records the names for
  the window's lifetime; another window asks again. Showing the sheet releases input
  capture, so keys stay on the Mac.
- Settings › Virtual monitors › "Automatically remove orphaned virtual monitors", off
  by default (`autoRemoveOrphanedMonitors`), read at each check: when on, found
  outputs (except ignored ones) are removed without a sheet and the session's status
  bar shows a summary for 10 seconds.
- A removal confirmed in the sheet is cancelled only by closing the window. A failed check or an
  unavailable host shows nothing.
- Logs (category `monitors`): counts, outcomes, unavailable reasons, error kinds and
  output names; never hosts, users, paths or error text.

## Hyprland behaviour (verified live)

On Hyprland 0.56 with a Lua configuration, with temporary headless outputs only:

- A window opened by a window rule on workspace 77, pinned to a headless output,
  survived the output's removal: workspace 77 moved to `eDP-1` with its window,
  nothing closed, the active workspace and focused window did not change.
- Disabling a headless output moved its workspaces to `eDP-1` at once.
- `output remove` on a disabled output replies `output not found` and keeps it;
  enabling it, then removing it works.
- Omarchy's `hyprmoncfgd` re-enables a disabled headless output within about a second.

## Tests and gate

`displays-reconnect` now also runs `cargo test -p gliff-mac-core monitors::` and the
`OrphanMonitorTests` suite.

- Bridge (14 tests): report parsing, 25 malformed or hostile reports, name validation,
  removal results, SSH argv; the real script under `/bin/sh` (and `/bin/dash` with
  `GLIFF_TEST_SHELL=/bin/dash`) against a fake `hyprctl` and `/proc`: classification
  (running server by name or build path, reused pid, dead, disabled, hostile names,
  other outputs), instance discovery and each unavailable reason, re-check before
  removal and again after enabling, enabling a disabled output (Lua, then keyword),
  unremovable outputs, unreadable command lines, Hyprland dying mid-removal;
  cancellation, time limit and a dropped call reaping the process group, redacted SSH failures,
  oversized output.
- App (12 tests): check after each connection without delaying it, mirror requests,
  Remove with mixed results, Ignore per window, automatic setting and its notice,
  cancellation of the check and of an automatic removal with the session, a confirmed
  removal surviving it, cancellation with the window, unavailable hosts and failed
  checks, no re-check while an offer waits, row texts.

## Live evidence

Omarchy host, unmodified server at the pin:

- `scripts/live-monitors-check.sh` ([summary](evidence/live-monitors.json)): with session
  A streaming, session B's server killed and a stray `gliff-<unused pid>` output, the
  check found exactly B's and the stray output; a check cancelled after 100 ms left no
  SSH process; removal removed both and kept A's (`InUse`, still streaming); afterwards
  no gliff output, server or local SSH process. Checks take about 10.5 s on this host
  because of its unreachable IPv6 address and `ConnectTimeout 10`.
- The app launched with the debug auto-connect hook ([steps and log](evidence/live-app.json)),
  with a second client's session running throughout: no offer at first; after a SIGKILL
  and the automatic reconnection the sheet offered only the killed server's output
  (read through the accessibility tree); Ignore, then another SIGKILL offered only the
  new orphan; Remove showed "Removed"; with the setting on, two more SIGKILLs were
  removed without a sheet and the status bar showed "Removed 1 orphaned virtual
  monitor."; the other client's output was never offered; quit drained cleanly and
  nothing was left on the host or the Mac.
- Earlier direct runs of the script removed a disabled orphan (`gliff-3999992`, reported
  `disabled` by the check).

Not verified live: a host without Hyprland (no second SSH host was available; covered
by the script tests with no `hyprctl`, no instance and an empty monitor list).

## Review

GPT Sol's review found five issues, all confirmed and fixed with regression tests: the
process check failed open on an unreadable command line; a server starting while its
disabled output was being enabled could lose it (no re-check right before removal); a
monitor query failing after removal read as "removed"; dropping a pending call left its
SSH running until the time limit; an automatic removal outlived its session. The live
check was rerun after the fixes.
