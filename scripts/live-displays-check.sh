#!/usr/bin/env bash
# Live display and lifecycle checks (task 10) against a Linux/Hyprland host.
#
# Runs crates/gliff-mac-core/examples/display_probe through the public bridge
# against the unmodified server that scripts/live-host-check.sh built on HOST,
# and checks the host and this Mac for leftovers after every scenario:
#
#   resize    headless Resize series (Retina and non-Retina, scale only)
#   mirror    mirror a temporary headless output by name (never a physical
#             monitor) and scale the stream to a smaller window
#   kill      SIGKILL the server mid-session: a link failure
#   stall     SIGSTOP the server: the silence limit ends the session
#   blackhole SIGSTOP the host's sshd for the session (a dropped network)
#   cycles    repeated connect/cancel with queued input
#
# usage: scripts/live-displays-check.sh HOST USER IDENTITY [SCENARIO]...
# Evidence: build/live-displays/<scenario>.json and summary.json (ignored).
set -euo pipefail
source "$(dirname "$0")/lib.sh"
cd "$GLIFF_ROOT"
require_command cargo
require_command ssh
require_command python3
die() { echo "error: $*" >&2; exit 1; }

[[ $# -ge 3 ]] || { sed -n '17p' "$0" >&2; exit 2; }
host="$1" user="$2" identity="$3"
shift 3
scenarios=("$@")
[[ ${#scenarios[@]} -gt 0 ]] || scenarios=(resize mirror kill stall blackhole cycles)
sha="$(cat upstream-revision)"
server="/home/$user/.cache/gliff-mac-live/gliff-server-$sha.bin"
out=build/live-displays
mkdir -p "$out"

remote() {
  # No ConnectTimeout: with one, OpenSSH can spend all of it on an address
  # family the host does not answer, which would distort detection times.
  ssh -o BatchMode=yes -i "$identity" "$user@$host" \
    'export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}";
     export HYPRLAND_INSTANCE_SIGNATURE="$(ls -t "$XDG_RUNTIME_DIR/hypr" | head -1)";'"$1"
}

cargo build --locked -q -p gliff-mac-core --example display_probe
probe=target/debug/examples/display_probe
remote "test -x '$server'" || die "no server at $server: run scripts/live-host-check.sh $host first"

# Leftovers after a scenario: gliff headless outputs and servers on the
# host, ssh children of this Mac's probe (identified by the policy file).
leftovers() {
  local outputs servers local_ssh
  outputs="$(remote "hyprctl monitors all -j | python3 -c 'import json,sys; print(sum(m[\"name\"].startswith(\"gliff-\") for m in json.load(sys.stdin)))'")"
  servers="$(remote "pgrep -c -f 'gliff-server.*[-]-stdio' || true")"
  local_ssh="$(pgrep -f 'gliff-ssh-' | wc -l | tr -d ' ')"
  printf '{"gliff_outputs":%s,"servers":%s,"local_ssh":%s}' "$outputs" "$servers" "$local_ssh"
}

settle() {
  # The server removes its output after EOF; give it a moment.
  for _ in $(seq 1 20); do
    [[ "$(leftovers)" == '{"gliff_outputs":0,"servers":0,"local_ssh":0}' ]] && break
    sleep 0.5
  done
}

# Runs `hold`, then `action` on the host once streaming; records the end.
# Patterns use `[-]-stdio` so that pgrep/pkill never match the remote shell
# running them.
held() {
  local name="$1" action="$2" cleanup="${3:-}"
  local fifo="$out/$name.stderr"
  rm -f "$fifo"
  "$probe" "$host" "$user" "$identity" "$server" hold 90 >"$out/$name.raw" 2>"$fifo" &
  local pid=$!
  for _ in $(seq 1 60); do grep -q streaming "$fifo" 2>/dev/null && break; sleep 0.5; done
  local start
  start="$(python3 -c 'import time; print(int(time.time()*1000))')"
  remote "$action"
  wait "$pid" || true
  local stop
  stop="$(python3 -c 'import time; print(int(time.time()*1000))')"
  [[ -n "$cleanup" ]] && remote "$cleanup"
  settle
  python3 - "$out/$name.raw" "$name" "$((stop - start))" "$(leftovers)" >"$out/$name.json" <<'EOF'
import json, sys
raw, name, detect_ms, left = sys.argv[1:]
data = json.load(open(raw))
data.update(scenario=name, detected_after_ms=int(detect_ms), leftovers=json.loads(left))
print(json.dumps(data))
EOF
  rm -f "$out/$name.raw" "$fifo"
}

for scenario in "${scenarios[@]}"; do
  echo "== $scenario"
  case "$scenario" in
    resize|cycles)
      arg=(); [[ $scenario == cycles ]] && arg=(10)
      "$probe" "$host" "$user" "$identity" "$server" "$scenario" ${arg[@]+"${arg[@]}"} >"$out/raw.json"
      settle
      python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); d["leftovers"]=json.loads(sys.argv[2]); print(json.dumps(d))' \
        "$out/raw.json" "$(leftovers)" >"$out/$scenario.json"
      rm -f "$out/raw.json"
      ;;
    mirror)
      # A temporary headless output shows only the default background.
      name="GLIFFMIRROR-$$"
      remote "hyprctl output create headless $name >/dev/null"
      trap 'remote "hyprctl output remove '"$name"' >/dev/null" || true' EXIT
      sleep 1
      "$probe" "$host" "$user" "$identity" "$server" mirror "$name" >"$out/raw.json" || true
      remote "hyprctl output remove $name >/dev/null"
      trap - EXIT
      settle
      python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); d["leftovers"]=json.loads(sys.argv[2]); print(json.dumps(d))' \
        "$out/raw.json" "$(leftovers)" >"$out/mirror.json"
      rm -f "$out/raw.json"
      ;;
    kill) held kill "pkill -KILL -f -- '$server [-]-stdio'" ;;
    stall) held stall "pkill -STOP -f -- '$server [-]-stdio'" "pkill -CONT -f -- '$server [-]-stdio' || true" ;;
    blackhole)
      # The session's sshd child is the parent of the server process.
      held blackhole "kill -STOP \$(ps -o ppid= -p \$(pgrep -f -- '$server [-]-stdio' | head -1))" \
        "for p in \$(pgrep -f -- '$server [-]-stdio'); do kill -CONT \$(ps -o ppid= -p \$p) 2>/dev/null; done; true"
      ;;
    *) die "unknown scenario $scenario" ;;
  esac
  python3 -m json.tool --compact "$out/$scenario.json" | cut -c1-400
done

python3 - "$out" "${scenarios[@]}" >"$out/summary.json" <<'EOF'
import json, sys
out, names = sys.argv[1], sys.argv[2:]
print(json.dumps({n: json.load(open(f"{out}/{n}.json")) for n in names}, indent=1))
EOF
echo "Evidence: $out/summary.json"
