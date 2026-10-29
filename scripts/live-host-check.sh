#!/usr/bin/env bash
# Live compatibility check against a Linux/Hyprland host.
#
# Builds the unmodified upstream gliff-server at an exact SHA on HOST, with
# upstream's own workspace and lockfile, then records a real --stdio session
# from this machine with the contract recorder and replays it through the
# app's client contract and the reference decoder. Hosted CI and mock peers
# cannot provide this evidence.
#
# usage: scripts/live-host-check.sh HOST [--sha SHA] [--video cpu|gpu]
#                                   [--chroma single420|dual420] [--resize WxH]
#                                   [--ssh-arg ARG]...
#
# HOST is an ssh destination with key/agent authentication and an active
# Hyprland session. Nothing is installed system-wide: sources, a private
# rustup toolchain (when the host has no cargo) and build output stay under
# ~/.cache/gliff-mac-live on the host. The server runs --headless, so it
# creates its own virtual output and never captures a physical monitor.
# That output shows no animation, so the server sends a frame only when the
# picture changes: the check takes the first keyframe, then sends a
# client Resize, which rebuilds the headless output and encoder, and takes the
# keyframe of the second configuration. Each step is bounded by a timeout.
# Evidence is written to build/live/<sha>-<video>-<chroma>/ (ignored by Git).
set -euo pipefail
source "$(dirname "$0")/lib.sh"
cd "$GLIFF_ROOT"
require_command git
require_command ssh
require_command cargo
require_command python3

host="${1:-}"
[[ -n "$host" && "$host" != -* ]] || {
  sed -n '10,13p' "$0" >&2
  exit 2
}
shift
sha="$(cat upstream-revision)"
video=cpu
chroma=single420
resize=1280x800
frames=4
ssh_opts=(-o BatchMode=yes -o ConnectTimeout=10)
while (($#)); do
  case "$1" in
    --sha) sha="$2"; shift 2 ;;
    --video) video="$2"; shift 2 ;;
    --chroma) chroma="$2"; shift 2 ;;
    --resize) resize="$2"; shift 2 ;;
    --ssh-arg) ssh_opts+=("$2"); shift 2 ;;
    *) printf 'Unknown option: %s\n' "$1" >&2; exit 2 ;;
  esac
done
[[ "$sha" =~ ^[0-9a-f]{40}$ ]] || { printf 'SHA must be a full 40-character commit.\n' >&2; exit 2; }
git -C vendor/gliff cat-file -e "$sha^{commit}" 2>/dev/null \
  || { printf 'Commit %s is not in vendor/gliff; fetch it first.\n' "$sha" >&2; exit 2; }

remote_root='.cache/gliff-mac-live'
out="build/live/${sha:0:12}-$video-$chroma"
rm -rf "$out"
mkdir -p "$out/png"
log="$out/live.log"
: > "$log"
step() { printf '== %s\n' "$*" | tee -a "$log"; }

step "Sending upstream $sha to $host"
git -C vendor/gliff update-ref refs/gliff-live/candidate "$sha"
bundle="$(mktemp)"
trap 'rm -f "$bundle"; git -C vendor/gliff update-ref -d refs/gliff-live/candidate' EXIT
git -C vendor/gliff bundle create "$bundle" refs/gliff-live/candidate 2>> "$log"
ssh "${ssh_opts[@]}" "$host" "mkdir -p $remote_root && cat > $remote_root/upstream.bundle" < "$bundle"

step "Building gliff-server with upstream's lockfile on $host"
# shellcheck disable=SC2087 # Expand the SHA and root locally on purpose.
ssh "${ssh_opts[@]}" "$host" bash -s >> "$log" 2>&1 <<EOF
set -euo pipefail
root="\$HOME/$remote_root"
src="\$root/src/$sha"
if [[ ! -d "\$src" ]]; then
  rm -rf "\$src.tmp"
  git init --quiet "\$src.tmp"
  git -C "\$src.tmp" fetch --quiet "\$root/upstream.bundle" refs/gliff-live/candidate
  git -C "\$src.tmp" checkout --quiet --detach "$sha"
  mv "\$src.tmp" "\$src"
fi
[[ -z "\$(git -C "\$src" status --porcelain)" ]] || { echo "remote source is modified"; exit 1; }
if ! command -v cargo >/dev/null; then
  export RUSTUP_HOME="\$root/rustup" CARGO_HOME="\$root/cargo"
  if [[ ! -x "\$CARGO_HOME/bin/cargo" ]]; then
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
      | sh -s -- -y --quiet --no-modify-path --profile minimal --default-toolchain 1.90.0
  fi
  export PATH="\$CARGO_HOME/bin:\$PATH"
fi
cd "\$src"
CARGO_TARGET_DIR="\$root/target" cargo build --release --locked -p gliff-server
cp "\$root/target/release/gliff-server" "\$root/gliff-server-$sha.bin"
EOF

step "Collecting host provenance"
host_info="$(ssh "${ssh_opts[@]}" "$host" bash -s 2>> "$log" <<EOF
set -euo pipefail
src="\$HOME/$remote_root/src/$sha"
printf '%s\n' "\$(uname -srm)"
. /etc/os-release && printf '%s\n' "\$PRETTY_NAME"
export XDG_RUNTIME_DIR="\${XDG_RUNTIME_DIR:-/run/user/\$(id -u)}"
export HYPRLAND_INSTANCE_SIGNATURE="\$(ls -t "\$XDG_RUNTIME_DIR/hypr" 2>/dev/null | head -1)"
hyprctl version -j 2>/dev/null | python3 -c 'import json,sys; v=json.load(sys.stdin); print(v.get("version") or v.get("tag") or "unknown")' 2>/dev/null || echo unknown
git -C "\$src" rev-parse HEAD
sha256sum "\$src/Cargo.lock" | cut -d' ' -f1
"\$HOME/$remote_root/gliff-server-$sha.bin" --version 2>/dev/null || echo unknown
EOF
)"
printf '%s\n' "$host_info" >> "$log"

step "Building the contract recorder"
cargo build --release --locked --manifest-path tools/fixture-gen/Cargo.toml >> "$log" 2>&1
gen=tools/fixture-gen/target/release/gliff-fixture-gen

server_args=(--stdio --headless --video "$video")
[[ "$chroma" == dual420 ]] && server_args+=(--full-chroma)
step "Recording $chroma frames from gliff-server ${server_args[*]}, client Resize to $resize"
started="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
status=passed
reason=""
if ! perl -e 'alarm shift; exec @ARGV' 120 \
    "$gen" record --chroma "$chroma" --frames "$frames" --out "$out/session.gliffstream" \
    --resize-after 1 --resize "$resize" \
    --command ssh -T "${ssh_opts[@]}" -o Compression=no "$host" \
    "\$HOME/$remote_root/gliff-server-$sha.bin" "${server_args[@]}" >> "$log" 2>&1; then
  status=failed
  reason="recording failed; see $log"
fi

if [[ "$status" == passed ]]; then
  step "Replaying the session through the client contract and reference decoder"
  provenance="$(python3 -c 'import json,sys; print(json.dumps({"kind": "live-compatibility-check", "upstream_sha": sys.argv[1]}))' "$sha")"
  if ! "$gen" describe "$out/session.gliffstream" --name live-check --provenance "$provenance" \
      --png-dir "$out/png" > "$out/session.json" 2>> "$log"; then
    status=failed
    reason="replay or reference decode failed; see $log"
  fi
fi

python3 - "$out" "$status" "$reason" "$host" "$sha" "$video" "$chroma" "$frames" "$started" "$resize" <<'PY' "$host_info"
import hashlib, json, pathlib, platform, subprocess, sys
out, status, reason, host, sha, video, chroma, frames, started, resize, info = sys.argv[1:]
info = (info.splitlines() + ["unknown"] * 6)[:6]
manifest_path = pathlib.Path(out, "session.json")
session = json.loads(manifest_path.read_text()) if manifest_path.exists() and status == "passed" else None
if session is not None:
    decoded = [f for f in session["frames"] if f.get("decoded_bgra_sha256")]
    if info[3] != sha:
        status, reason = "failed", "remote source is %s, expected %s" % (info[3], sha)
    elif len(decoded) < int(frames):
        status, reason = "failed", "only %d of %s frames decoded" % (len(decoded), frames)
    elif len(session["configs"]) < 2:
        status, reason = "failed", "the client Resize did not produce a second configuration"
evidence = {
    "gate": "live-host",
    "status": status,
    "reason": reason or None,
    "date": started,
    "client": {
        "source_sha": subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip(),
        "dirty": bool(subprocess.check_output(["git", "status", "--porcelain"], text=True).strip()),
        "os": "%s %s" % (platform.system(), platform.mac_ver()[0] or platform.release()),
        "arch": platform.machine(),
        "recorder": "tools/fixture-gen record (minimal Hello/Pong/FrameAck client over the app contract)",
    },
    "server": {
        "host": host,
        "source_sha": info[3],
        "lockfile_sha256": info[4],
        "version": info[5],
        "kernel": info[0],
        "os": info[1],
        "hyprland": info[2],
        "arguments": ["--stdio", "--headless", "--video", video] + (["--full-chroma"] if chroma == "dual420" else []),
    },
    "session": None if session is None else {
        "chroma": chroma,
        "frames_requested": int(frames),
        "client_resize": resize,
        "frames_recorded": len(session["frames"]),
        "frames_decoded": sum(1 for f in session["frames"] if f.get("decoded_bgra_sha256")),
        "messages": session["messages"][:4] + (["..."] if len(session["messages"]) > 4 else []),
        "configs": [{k: c.get(k) for k in ("codec", "chroma", "pipeline", "width", "height", "fps_cap")}
                    for c in session["configs"]],
        "stream_sha256": hashlib.sha256(pathlib.Path(out, "session.gliffstream").read_bytes()).hexdigest(),
    },
}
pathlib.Path(out, "evidence.json").write_text(json.dumps(evidence, indent=2) + "\n")
print(json.dumps(evidence, indent=2))
PY
[[ "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["status"])' "$out/evidence.json")" == passed ]]
