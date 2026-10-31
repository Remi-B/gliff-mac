# Orphaned Gliff virtual monitors (task 14). A fixed POSIX sh script that the
# bridge sends on stdin to `sh -s -- check` or `sh -s -- remove NAME...` over
# SSH; nothing of the user's is interpolated into it, and NAMEs are validated
# `gliff-<pid>` names, checked again here.
#
# In virtual display mode the server creates a headless output named
# gliff-<pid> and removes it when it exits. An output is an orphan when its
# name matches and no running process with that pid is a gliff-server.
#
# Every report line starts with "gliff-orphans 1" and is parsed strictly by
# `monitors.rs`:
#   unavailable no-hyprctl|no-hyprland|hyprctl-failed
#   begin
#   orphan NAME WIDTH HEIGHT enabled|disabled     (check)
#   removed|in-use|failed NAME                    (remove)
#   end COUNT
set -u
LC_ALL=C
export LC_ALL
# Tests point this at a fake process table; it is /proc on a real host.
proc=${GLIFF_ORPHANS_PROC:-/proc}

say() { printf 'gliff-orphans 1 %s\n' "$*"; }

# gliff-<pid>: digits only, no leading zero, at most 7 digits (pid_max).
valid_name() {
  case $1 in
  gliff-*) ;;
  *) return 1 ;;
  esac
  set -- "${1#gliff-}"
  case $1 in
  '' | *[!0-9]* | 0*) return 1 ;;
  esac
  [ ${#1} -le 7 ]
}

# A pid can be reused: the output is in use only while that pid runs a
# program named gliff-server (gliff-server-<sha>.bin for development builds).
# Fails safe: a process whose command line cannot be read counts as running.
server_running() {
  [ -e "$proc/$1" ] || return 1
  [ -r "$proc/$1/cmdline" ] || return 0
  argv0=$(tr '\0' '\n' <"$proc/$1/cmdline" 2>/dev/null | head -n 1) || return 0
  case ${argv0##*/} in
  gliff-server*) return 0 ;;
  esac
  return 1
}

# NAME WIDTH HEIGHT DISABLED per monitor, disabled ones included. Fails
# when Hyprland does not answer with a monitor list.
monitors() {
  all=$(hyprctl monitors all 2>/dev/null) || return 1
  case $all in *"Monitor "*) ;; *) return 1 ;; esac
  printf '%s\n' "$all" | awk '
    function row() { print name, (w == "" ? "-" : w), (h == "" ? "-" : h), (off == "" ? "-" : off) }
    /^Monitor / { if (name != "") row(); name = $2; w = ""; h = ""; off = ""; next }
    name != "" && w == "" && $1 ~ /^[0-9]+x[0-9]+@/ {
      split($1, at, "@"); split(at[1], size, "x"); w = size[1]; h = size[2]; next
    }
    name != "" && $1 == "disabled:" { off = $2 }
    END { if (name != "") row() }'
}

# enabled, disabled, absent, or unknown when Hyprland does not answer.
state_of() {
  rows=$(monitors) || { echo unknown; return; }
  printf '%s\n' "$rows" | awk -v want="$1" '
    $1 == want { print ($4 == "true" ? "disabled" : "enabled"); found = 1; exit }
    END { if (!found) print "absent" }'
}

# Waits up to about two seconds for NAME to reach STATE.
await_state() {
  tries=0
  while [ "$(state_of "$1")" != "$2" ]; do
    tries=$((tries + 1))
    [ $tries -le 10 ] || return 1
    sleep 0.2 2>/dev/null || sleep 1
  done
}

command -v hyprctl >/dev/null 2>&1 || { say unavailable no-hyprctl; exit 0; }

# The Hyprland instance: the environment's when it answers, else the newest
# one under the runtime directory that answers (SSH sessions name none).
XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}
export XDG_RUNTIME_DIR
answers() { HYPRLAND_INSTANCE_SIGNATURE=$1 hyprctl monitors all 2>/dev/null | grep -q '^Monitor '; }
instance=
if [ -n "${HYPRLAND_INSTANCE_SIGNATURE:-}" ] && answers "$HYPRLAND_INSTANCE_SIGNATURE"; then
  instance=$HYPRLAND_INSTANCE_SIGNATURE
else
  for dir in $(ls -t "$XDG_RUNTIME_DIR/hypr" 2>/dev/null); do
    case $dir in *[!A-Za-z0-9_]*) continue ;; esac
    if [ -S "$XDG_RUNTIME_DIR/hypr/$dir/.socket.sock" ] && answers "$dir"; then
      instance=$dir
      break
    fi
  done
fi
[ -n "$instance" ] || { say unavailable no-hyprland; exit 0; }
HYPRLAND_INSTANCE_SIGNATURE=$instance
export HYPRLAND_INSTANCE_SIGNATURE

list=$(monitors) || { say unavailable hyprctl-failed; exit 0; }

case ${1:-} in
check)
  say begin
  count=0
  # The list is a variable, not a pipe, so the count survives the loop.
  while read -r name width height disabled; do
    valid_name "$name" || continue
    server_running "${name#gliff-}" && continue
    case $width$height in '' | *[!0-9]*) width=0 height=0 ;; esac
    case $disabled in true) state=disabled ;; *) state=enabled ;; esac
    say orphan "$name" "$width" "$height" "$state"
    count=$((count + 1))
  done <<EOF
$list
EOF
  say end "$count"
  ;;
remove)
  shift
  say begin
  for name in "$@"; do
    if ! valid_name "$name"; then
      say failed "$name"
      continue
    fi
    # Re-checked right before removing: its server may run again.
    if server_running "${name#gliff-}"; then
      say in-use "$name"
      continue
    fi
    state=$(state_of "$name")
    # Already gone (removed meanwhile) counts as removed.
    [ "$state" = absent ] && { say removed "$name"; continue; }
    [ "$state" = unknown ] && { say failed "$name"; continue; }
    # Hyprland cannot remove a disabled output ("output not found"), which
    # is how a monitor tool leaves one behind: enable it first.
    if [ "$state" = disabled ]; then
      hyprctl eval "hl.monitor({ output = \"$name\", disabled = false })" >/dev/null 2>&1
      if ! await_state "$name" enabled; then
        hyprctl keyword monitor "$name,preferred,auto,1" >/dev/null 2>&1
        await_state "$name" enabled
      fi
      # Enabling can take seconds: check its server again.
      if server_running "${name#gliff-}"; then
        say in-use "$name"
        continue
      fi
    fi
    hyprctl output remove "$name" >/dev/null 2>&1
    # hyprctl answers even when nothing was removed: verify.
    if await_state "$name" absent; then say removed "$name"; else say failed "$name"; fi
  done
  say end $#
  ;;
*)
  exit 2
  ;;
esac
