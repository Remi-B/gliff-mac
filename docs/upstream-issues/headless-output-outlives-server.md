# Headless output outlives its server

- **Repository:** [`omacom/gliff`](https://github.com/omacom/gliff)
- **Title:** Headless `gliff-<pid>` output stays in Hyprland when the server is killed or its output is disabled
- **Status:** draft, not filed. Written against `58c742452ded3f10a2ce61f60eb4845f18205e29`
  (Gliff 0.4.1); check the current upstream code before filing.
- **Origin:** task [14](../14-clean-up-orphan-monitors/README.md). The macOS app keeps no
  patch to the vendored server and only cleans up after it.

Everything below the line is the issue body.

---

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

Reproduced on Hyprland 0.56 with the unmodified server: every SIGKILL of the server
left its output, and a disabled output could be removed only after being enabled
again. (gliff-mac: `scripts/live-monitors-check.sh` and the
[task 14 implementation record](../14-clean-up-orphan-monitors/implementation-record.md).)
