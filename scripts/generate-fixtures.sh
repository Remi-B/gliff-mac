#!/usr/bin/env bash
# Regenerate the synthetic contract fixtures and their manifests.
#
# The streams are encoded by upstream's CPU encoder (gliff-sw, OpenH264) and
# framed by upstream gliff-transport at the pinned SHA. OpenH264 slices a
# picture per encoder thread (min(CPUs, 4)) and uses per-architecture SIMD,
# so the bytes are reproducible for a given thread count and architecture;
# the manifest records both. Pass --check to verify
# the committed fixtures instead of rewriting them.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
cd "$GLIFF_ROOT"
require_command cargo
require_command python3

check=false
[[ "${1:-}" == --check ]] && check=true

cargo build --release --locked --manifest-path tools/fixture-gen/Cargo.toml
gen=tools/fixture-gen/target/release/gliff-fixture-gen
out=tests/fixtures/streams
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

pin="$(cat upstream-revision)"
cpus="$(python3 -c 'import os; print(os.cpu_count())')"
threads=$(( cpus < 4 ? cpus : 4 ))
arch="$(uname -m)"
[[ "$arch" == aarch64 ]] && arch=arm64
openh264="$(python3 - <<'PY'
import re
lock = open("tools/fixture-gen/Cargo.lock").read()
print(re.search(r'name = "openh264"\nversion = "([^"]+)"', lock).group(1))
PY
)"
rustc_version="$(rustc --version)"
host="$(uname -sm)"

for chroma in single420 dual420; do
  name="synthetic-$chroma"
  command="gliff-fixture-gen synth --chroma $chroma --out $name.gliffstream"
  "$gen" synth --chroma "$chroma" --out "$work/$name.gliffstream"
  provenance="$(python3 - "$pin" "$command" "$threads" "$arch" "$openh264" "$rustc_version" "$host" <<'PY'
import json, sys
pin, command, threads, arch, openh264, rustc, host = sys.argv[1:]
print(json.dumps({
    "kind": "synthetic-server-equivalent",
    "summary": "Deterministic synthetic BGRA frames encoded by upstream gliff_sw::Encoder "
               "(the gliff-server --video cpu encoder) and framed by upstream "
               "gliff_transport::Framed in gliff-server's message order. Not a live "
               "gliff-server capture: no Hyprland capture, rate control or GPU encoder ran.",
    "upstream_sha": pin,
    "generator": "tools/fixture-gen",
    "command": command,
    "settings": {"bitrate_bps": 1500000, "fps": 30, "paced_fps": 15,
                 "profile": "Baseline (gliff-sw)", "encoder_threads": int(threads), "encoder_arch": arch,
                 "segments": ["320x192 x10, forced IDR at index 6, fps cap 30->15 after index 7",
                              "384x240 x6 (headless resize, encoder rebuilt)"]},
    "encoder": "openh264 " + openh264 + " (built from source)",
    "toolchain": rustc,
    "host": host,
}))
PY
)"
  "$gen" describe "$work/$name.gliffstream" --name "$name" --provenance "$provenance" \
    > "$work/$name.json"
  if $check; then
    # The committed stream must replay through `record` byte for byte.
    "$gen" record --chroma "$chroma" --frames 16 --out "$work/$name.recorded" \
      --command "$gen" serve "$out/$name.gliffstream" 2>/dev/null
    cmp "$work/$name.recorded" "$out/$name.gliffstream"
    # Re-describe the committed stream with its committed provenance: the
    # manifest (checksums, NAL types, decoded hashes, PSNR) must match on
    # any host, whatever produced the bytes.
    "$gen" describe "$out/$name.gliffstream" --name "$name" \
      --provenance "$(python3 -c 'import json, sys; print(json.dumps(json.load(open(sys.argv[1]))["provenance"]))' "$out/$name.json")" \
      > "$work/$name.redescribed.json"
    python3 - "$work/$name.redescribed.json" "$out/$name.json" <<'PY'
import json, sys
fresh, committed = (json.load(open(p)) for p in sys.argv[1:])
if fresh != committed:
    raise SystemExit("committed manifest does not describe its stream: " + sys.argv[2])
PY
    committed="$(python3 -c 'import json, sys; s = json.load(open(sys.argv[1]))["provenance"]["settings"]; print(s["encoder_threads"], s["encoder_arch"])' "$out/$name.json")"
    if [[ "$committed" != "$threads $arch" ]]; then
      printf '%s: encoded with OpenH264 threads/arch %s, this host is %s; fresh-generation comparison skipped.\n' \
        "$name" "$committed" "$threads $arch"
      continue
    fi
    cmp "$work/$name.gliffstream" "$out/$name.gliffstream"
    python3 - "$work/$name.json" "$out/$name.json" <<'PY'
import json, sys
fresh, committed = (json.load(open(p)) for p in sys.argv[1:])
for m in (fresh, committed):
    m["provenance"].pop("toolchain", None)
    m["provenance"].pop("host", None)
if fresh != committed:
    raise SystemExit("manifest differs from a fresh generation: " + sys.argv[2])
PY
  else
    mkdir -p "$out"
    cp "$work/$name.gliffstream" "$work/$name.json" "$out/"
  fi
done
if $check; then
  printf 'Fixtures replay and match a fresh generation where comparable.\n'
else
  printf 'Fixtures written to %s.\n' "$out"
fi
