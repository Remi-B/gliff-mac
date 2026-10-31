#!/usr/bin/env bash
# Live orphaned-monitor checks (task 14) against a Linux/Hyprland host.
#
# Uses the public bridge (examples/monitor_probe and display_probe) and the
# unmodified server that scripts/live-host-check.sh built on HOST:
#
#   1. session A streams: its gliff-<pid> output is in use;
#   2. session B's server is killed with SIGKILL: its output is orphaned;
#   3. a temporary headless gliff-<unused pid> output: a stray with no server
#      (Omarchy's monitor daemon re-enables a disabled output within about a
#      second, so disabled orphans are covered by the bridge tests instead);
#   4. check: exactly B's and the stray output are found, never A's;
#   5. a check cancelled after 100 ms leaves no SSH process;
#   6. removal of all three: B's and the stray one removed, A's in use and
#      still streaming;
#   7. once A ends: no gliff output, server or local SSH process is left.
#
# Only headless outputs are created; the physical monitor is never captured.
# usage: scripts/live-monitors-check.sh HOST USER IDENTITY
# Evidence: build/live-monitors/summary.json (ignored).
set -euo pipefail
source "$(dirname "$0")/lib.sh"
cd "$GLIFF_ROOT"
require_command cargo
require_command ssh
require_command python3
die() { echo "error: $*" >&2; exit 1; }

[[ $# -eq 3 ]] || { sed -n '18p' "$0" >&2; exit 2; }
host="$1" user="$2" identity="$3"
sha="$(cat upstream-revision)"
server="/home/$user/.cache/gliff-mac-live/gliff-server-$sha.bin"
out=build/live-monitors
mkdir -p "$out"

remote() {
  # No ConnectTimeout: see live-displays-check.sh.
  ssh -o BatchMode=yes -i "$identity" "$user@$host" \
    'export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}";
     export HYPRLAND_INSTANCE_SIGNATURE="$(ls -t "$XDG_RUNTIME_DIR/hypr" | head -1)";'"$1"
}

cargo build --locked -q -p gliff-mac-core --example display_probe --example monitor_probe
display=target/debug/examples/display_probe
monitors=target/debug/examples/monitor_probe
remote "test -x '$server'" || die "no server at $server: run scripts/live-host-check.sh $host first"
[[ "$(remote "hyprctl monitors all | grep -c '^Monitor gliff-'" || true)" == 0 ]] ||
  die "the host already has gliff outputs: remove them before this check"

servers() { remote "pgrep -f -- '$server [-]-stdio' | sort -n | tr '\n' ' '" || true; }
local_ssh() { { pgrep -f 'gliff-ssh-' || true; } | wc -l | tr -d ' '; }
# SSH processes of monitor checks or removals (`sh -s -- check|remove`).
check_ssh() { { pgrep -f 'sh -s -- (check|remove)' || true; } | wc -l | tr -d ' '; }
cleanup() {
  local left=()
  [[ -n "${fake:-}" ]] && left+=("$fake")
  [[ -n "${orphan_b:-}" ]] && left+=("$orphan_b")
  [[ ${#left[@]} -gt 0 ]] && "$monitors" "$host" "$user" "$identity" remove "${left[@]}" >/dev/null || true
  [[ -n "${pid_a:-}" ]] && kill "$pid_a" 2>/dev/null || true
}
trap cleanup EXIT

# Starts a held session in `held` and returns once it streams.
hold() {
  local name="$1" seconds="$2"
  "$display" "$host" "$user" "$identity" "$server" hold "$seconds" >"$out/$name.json" 2>"$out/$name.stderr" &
  held=$!
  for _ in $(seq 1 60); do grep -q streaming "$out/$name.stderr" 2>/dev/null && return; sleep 0.5; done
  die "session $name did not stream"
}

echo "== sessions"
# A outlives the checks below, then ends by itself.
hold a 45
pid_a=$held
server_a="$(servers)"
hold b 90
pid_b=$held
server_b="$(comm -13 <(tr ' ' '\n' <<<"$server_a" | sed '/^$/d' | sort) <(servers | tr ' ' '\n' | sed '/^$/d' | sort))"
[[ -n "$server_b" ]] || die "session B's server not found"
server_a="$(tr -d ' ' <<<"$server_a")"
remote "kill -KILL $server_b"
orphan_b="gliff-$server_b"
wait "$pid_b" || true

# An unused pid for the stray output.
fake_pid="$(remote 'p=3999990; while [ -e /proc/$p ]; do p=$((p-1)); done; echo $p')"
fake="gliff-$fake_pid"
remote "hyprctl output create headless $fake >/dev/null; sleep 1"
before="$(remote "hyprctl monitors all | grep '^Monitor gliff-' | cut -d' ' -f2 | sort | tr '\n' ' '")"
echo "outputs: $before (A gliff-$server_a, B gliff-$server_b, stray $fake)"

echo "== check"
"$monitors" "$host" "$user" "$identity" check | tee "$out/check.json"
echo "== cancel"
"$monitors" "$host" "$user" "$identity" cancel | tee "$out/cancel.json"
sleep 0.5
cancel_ssh="$(check_ssh)"
echo "== remove"
"$monitors" "$host" "$user" "$identity" remove "gliff-$server_b" "$fake" "gliff-$server_a" | tee "$out/remove.json"
fake="" orphan_b=""
after_remove="$(remote "hyprctl monitors all | grep '^Monitor gliff-' | cut -d' ' -f2 | sort | tr '\n' ' '")"
a_streaming="$(kill -0 "$pid_a" 2>/dev/null && echo true || echo false)"

echo "== end of session A"
wait "$pid_a" || true
pid_a=""
for _ in $(seq 1 20); do
  left="$(remote "hyprctl monitors all | grep -c '^Monitor gliff-'" || true)"
  [[ "$left" == 0 && -z "$(servers | tr -d ' ')" && "$(local_ssh)" == 0 ]] && break
  sleep 0.5
done

status=0
python3 - "$out" "$server_a" "$server_b" "$fake_pid" "$before" "$after_remove" "$a_streaming" \
  "$cancel_ssh" "$left" "$(servers | tr -d ' ')" "$(local_ssh)" >"$out/summary.json" <<'EOF' || status=$?
import json, sys
out, a, b, fake, before, after, streaming, cancel_ssh, left, servers, local_ssh = sys.argv[1:]
load = lambda name: json.load(open(f"{out}/{name}.json"))
check, cancel, remove = load("check"), load("cancel"), load("remove")
found = sorted(o["name"] for o in check.get("found", []))
outcomes = {r["name"]: r["outcome"] for r in remove.get("results", [])}
summary = {
    "outputs_before": before.split(),
    "check": check, "cancel": cancel, "remove": remove,
    "outputs_after_removal": after.split(),
    "session_a_streaming_after_removal": streaming == "true",
    "local_ssh_after_cancel": int(cancel_ssh),
    "leftovers": {"gliff_outputs": int(left or 0), "servers": len(servers.split()), "local_ssh": int(local_ssh)},
}
summary["passed"] = {
    "orphans_found_running_session_not": found == sorted([f"gliff-{b}", f"gliff-{fake}"]),
    "cancelled": cancel.get("cancelled") is True and int(cancel_ssh) == 0,
    "removed": outcomes.get(f"gliff-{b}") == "Removed" and outcomes.get(f"gliff-{fake}") == "Removed",
    "running_session_kept": outcomes.get(f"gliff-{a}") == "InUse" and after.split() == [f"gliff-{a}"] and streaming == "true",
    "no_leftovers": int(left or 0) == 0 and not servers.split() and int(local_ssh) == 0,
}
print(json.dumps(summary, indent=1))
sys.exit(0 if all(summary["passed"].values()) else 1)
EOF

python3 -c 'import json,sys; print(json.dumps(json.load(open(sys.argv[1]))["passed"], indent=1))' "$out/summary.json"
echo "Evidence: $out/summary.json"
exit $status
