# Upstream proposal: headless outputs that outlive their server

Draft for an issue on [`omacom/gliff`](https://github.com/omacom/gliff), written against
the pinned revision `58c742452ded3f10a2ce61f60eb4845f18205e29` (Gliff 0.4.1). Not filed:
publishing it is the maintainer's decision. The macOS app keeps no patch to the
vendored server; task 14 only cleans up after it.

## Problem

In virtual display mode the server creates `gliff-<pid>` (`crates/gliff-server/src/session.rs`,
`create_headless_output`) and removes it when `SessionOutput` drops:

```rust
if let Some(instance) = &self.headless {
    let _ = instance.remove_output(&self.name);
}
```

The output stays in Hyprland, invisible but still a monitor that can receive
workspaces and windows, in two cases reproduced on Hyprland 0.56 (Lua configuration):

1. **The server is killed** (SIGKILL, OOM, crash in a non-unwinding path): `Drop` never
   runs. Every killed session leaves its output.
2. **The output is disabled when the server removes it.** Hyprland answers
   `output remove` for a disabled output with `output not found` and keeps it (the
   reply still exits 0). Omarchy's monitor daemon (`hyprmoncfgd`) disables outputs
   while the user switches displays and re-enables them about a second later: a
   server that exits in that window ignores the failed removal, and the output comes
   back with no server.

## Suggested changes

- **Verify the removal.** After `output remove`, list the monitors and check that the
  name is gone; retry a few times with a short delay. If the output is disabled,
  enable it first (`eval hl.monitor({ output = "NAME", disabled = false })`, or the
  `monitor NAME,preferred,auto,1` keyword on a hyprlang configuration), then remove it.
  `hyprctl` replies `ok` or `output not found` with status 0, so the reply text, not
  the status, says whether anything happened.
- **Survive a disabled/re-enabled output.** Treat the output disappearing or turning
  disabled during a session as a pause, not an error, and wait for it to come back
  (with a bound) before ending the session.
- **Remove its own stale outputs at startup.** Before creating `gliff-<pid>`, remove
  `gliff-<n>` outputs whose `/proc/<n>/cmdline` is not a running `gliff-server` (the
  pid can be reused). This covers SIGKILL, which no in-process cleanup can.
  Containerized servers (another pid namespace) would look orphaned: an opt-out flag
  may be needed.

## Evidence

`scripts/live-monitors-check.sh` and the [implementation record](implementation-record.md)
in this repository: every SIGKILL of the server left its output; a disabled output
was removed only after being enabled.
