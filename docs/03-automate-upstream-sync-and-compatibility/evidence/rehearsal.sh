#!/usr/bin/env bash
# Disposable rehearsal of the upstream update/rollback workflow.
# usage: rehearsal.sh SOURCE_WORKTREE OUT_LOG
set -uo pipefail
src="$1"; log="$2"
export PATH=/opt/homebrew/opt/rustup/bin:$PATH
work="$(mktemp -d /tmp/gliff-rehearsal.XXXX)"
exec > >(tee "$log") 2>&1
say() { printf '\n### %s\n' "$*"; }
run() { printf '$ %s\n' "$*"; "$@"; local c=$?; printf '[exit %s]\n' "$c"; return $c; }

say "Disposable clone of the feature branch ($work)"
git clone --quiet "$src" "$work/app"
cd "$work/app"
git -c protocol.file.allow=always submodule update --init --recursive --quiet
git -C vendor/gliff fetch --quiet --tags https://github.com/omacom/gliff.git '+refs/heads/main:refs/remotes/origin/main'
pin="$(cat upstream-revision)"
echo "pin $pin"

say "1. Baseline candidate (upstream main == pin): rehearsal, nothing staged"
run python3 scripts/upstream.py status
run python3 scripts/upstream.py update "$pin" --report "$work/baseline.md"
run git status --porcelain

say "2. Abbreviated SHA and branch name are refused"
run python3 scripts/upstream.py update "${pin:0:12}"
run python3 scripts/upstream.py update main

say "3. Stale pin (v0.4.0) is refused, not reported as an upgrade"
old="$(git -C vendor/gliff rev-list -n1 v0.4.0)"
run python3 scripts/upstream.py update "$old"

say "4. Simulated newer upstream commit with an incompatible protocol change"
# A local commit on top of the pin stands in for a new upstream main; no fetch.
git -C vendor/gliff checkout --quiet --detach "$pin"
sed -i '' 's/^pub const PROTOCOL_VERSION: u16 = 1;/pub const PROTOCOL_VERSION: u16 = 2;/' vendor/gliff/crates/gliff-proto/src/msg.rs
python3 - <<'PY'
import re
p = "vendor/gliff/crates/gliff-proto/src/msg.rs"
s = open(p).read()
# Renumber FrameAck.decoded_at_ms (#[n(1)] -> #[n(2)]): an incompatible field change.
s = s.replace("        frame_id: u64,\n        #[n(1)]\n        decoded_at_ms: u64,",
              "        frame_id: u64,\n        #[n(2)]\n        decoded_at_ms: u64,", 1)
open(p, "w").write(s)
PY
git -C vendor/gliff -c user.name=rehearsal -c user.email=rehearsal@invalid commit --quiet -am "Rehearsal: incompatible protocol change"
bad="$(git -C vendor/gliff rev-parse HEAD)"
git -C vendor/gliff update-ref refs/remotes/origin/main "$bad"
git -C vendor/gliff checkout --quiet --detach "$pin"
echo "simulated upstream main $bad"

say "5. A clean bootstrap stays on the pin although upstream main moved"
run scripts/bootstrap.sh
run git -C vendor/gliff rev-parse HEAD
run python3 scripts/upstream.py status --no-fetch

say "6. Update to the incompatible candidate"
run python3 scripts/upstream.py update "$bad" --no-fetch --report "$work/incompatible.md"
git -c user.name=rehearsal -c user.email=rehearsal@invalid commit --quiet -m "Update upstream gliff to ${bad:0:12} (rehearsal)"
run git show --stat --format='%h %s' HEAD
sed -n '/## Review flags/,/## Commits/p' "$work/incompatible.md"

say "7. The gate fails with a useful reason"
run python3 scripts/gates.py --only structure,compatibility-records,protocol-surface,rust-tests --summary "$work/incompatible-gates.json"
grep -A12 'upstream wire surface differs' build/gates/logs/protocol-surface.log | head -16
run python3 scripts/upstream.py qualify --gates "$work/incompatible-gates.json"

say "8. Rollback: revert the update commit and restore the submodule"
run git revert --no-edit HEAD
run git submodule update --init --recursive
run git -C vendor/gliff rev-parse HEAD
run python3 scripts/gates.py --only structure,compatibility-records,protocol-surface,rust-tests --summary "$work/rollback-gates.json"

say "9. Stale-pin rehearsal with --allow-stale, then abort"
run python3 scripts/upstream.py update "$old" --allow-stale --report "$work/stale.md"
python3 -c 'import json; c=json.load(open("tests/compatibility/matrix.json"))["records"]["candidate"]; print("candidate record:", c["relation"], c["result"], c["upstream"]["describe"])'
sed -n '/## Review flags/,/## Changes/p' "$work/stale.md"
run python3 scripts/upstream.py abort
run git status --porcelain
echo "work dir: $work"
