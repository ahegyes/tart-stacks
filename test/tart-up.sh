#!/usr/bin/env bash
# Characterization tests for bin/tart-up's runtime flow — no real VM, no real
# sleeps. Mocked `tart` (list/run/ip/exec; `list` fails on demand via
# MOCK_TART_LIST_RC), `nc` (logs its argv, exits $MOCK_NC_RC; reached through
# the $TART_NC_BIN seam, not PATH) and `ps` (MOCK_PS_LINE/MOCK_ALIVE fake the
# `tart run` cmdline the liveness scan reads) make the IP poll and the :22
# probe converge on the first iteration. Covers resolve + prefix lookup, the
# tart-list failure path, base-image refusal, the stopped→`tart run` command
# (netpolicy gating + mount/gui flags + stderr log capture), fail-closed gui
# parsing, started-only desktop activation + window backing-scale application,
# the running-VM paths (alive vs wedged), and the hostname-set branch. Plain
# bash, no framework.
# Run via script/test or directly.
set -uo pipefail

TEST_DIR=$(cd -P "$(dirname "$0")" >/dev/null 2>&1 && pwd)
REPO=$(cd -P "$TEST_DIR/.." >/dev/null 2>&1 && pwd)
BIN="$REPO/bin"

pass=0 fail=0
ok()  { pass=$((pass + 1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  FAIL %s\n         %s\n' "$1" "${2:-}"; }
assert_eq()       { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "want » $2 « got » $3 «"; fi; }
assert_contains() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "want » $3 « in: $2" ;; esac; }
assert_path()     { if [ -e "$2" ]; then ok "$1"; else bad "$1" "missing: $2"; fi; }
assert_no_path()  { if [ -e "$2" ]; then bad "$1" "should not exist: $2"; else ok "$1"; fi; }
assert_absent()   { case "$2" in *"$3"*) bad "$1" "should NOT contain » $3 «" ;; *) ok "$1" ;; esac; }
check_rc() { local l="$1" want="$2"; shift 2; local got=0; "$@" >/dev/null 2>&1 || got=$?
  if [ "$got" -eq "$want" ]; then ok "$l"; else bad "$l" "want rc=$want got rc=$got"; fi; }
assert_rc() { # label want — checks $rc from the last runup
  if [ "$rc" -eq "$2" ]; then ok "$1"; else bad "$1" "want rc=$2 got rc=$rc"; fi; }
line_of() { grep -nF -- "$1" "$CALLS" 2>/dev/null | head -n 1 | cut -d: -f1; }
assert_order() { # label earlier-needle later-needle — both in $CALLS, in that order
  local l="$1" a b
  a=$(line_of "$2"); b=$(line_of "$3")
  if [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ]; then ok "$l"
  else bad "$l" "want » $2 « (line ${a:-absent}) before » $3 « (line ${b:-absent}) in: $(tr '\n' '|' < "$CALLS")"; fi
}

WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
MOCKBIN="$WORK/bin"; mkdir -p "$MOCKBIN"
# HOME is sandboxed so nothing the commands derive from it can reach the
# developer's real dotfiles when the suite runs.
SANDBOX_HOME="$WORK/home"; mkdir -p "$SANDBOX_HOME"
CALLS="$WORK/calls"; export CALLS
ERR="$WORK/stderr"
EMPTY="$WORK/empty"; : > "$EMPTY"
SS_COUNT="$WORK/ss-count"

# Mock `tart`: `list` emits one VM (name=$MOCK_VM, state=$MOCK_STATE), or —
# with MOCK_TART_LIST_RC nonzero — prints a stderr marker and fails with that
# rc; `ip` returns $MOCK_IP; `exec <vm> hostname -s` returns $MOCK_HOSTNAME
# (drives the set-hostname branch); `exec <vm> ss -tln` emits either the fixed
# $MOCK_SS_OUTPUT or successive lines from $MOCK_SS_SEQUENCE_FILE (the
# <absent> sentinel emits an empty table). MOCK_TART_EXEC_FAIL_MATCH makes one
# exact exec argv fail; MOCK_TART_FAIL_MATCH can fail any full tart argv.
# `run` and every call are logged to $CALLS.
cat > "$MOCKBIN/tart" <<'TART'
#!/usr/bin/env bash
echo "tart $*" >> "$CALLS"
if [ -n "${MOCK_TART_FAIL_MATCH:-}" ] && [ "$*" = "$MOCK_TART_FAIL_MATCH" ]; then
  exit 1
fi
case "$1" in
  list)
    if [ "${MOCK_TART_LIST_RC:-0}" -ne 0 ]; then
      echo "MOCK_TART_LIST_STDERR_MARKER" >&2
      exit "${MOCK_TART_LIST_RC}"
    fi
    printf '[{"Name":"%s","Source":"local","State":"%s"}]\n' "${MOCK_VM:-app-a}" "${MOCK_STATE:-stopped}" ;;
  ip)   printf '%s\n' "${MOCK_IP-10.0.0.9}" ;;   # set MOCK_IP='' to drive the no-lease path
  exec)
    shift 2
    if [ -n "${MOCK_TART_EXEC_FAIL_MATCH:-}" ] && [ "$*" = "$MOCK_TART_EXEC_FAIL_MATCH" ]; then
      exit 1
    fi
    case "$*" in
      "hostname -s") printf '%s\n' "${MOCK_HOSTNAME:-app-a}" ;;
      "ss -tln"|"sudo ss -tln")
        [ "${MOCK_SS_READ_FAIL:-0}" -eq 0 ] || exit 1
        if [ -n "${MOCK_SS_SEQUENCE_FILE:-}" ]; then
          call=0
          read -r call < "$MOCK_SS_COUNT_FILE" 2>/dev/null || call=0
          call=$((call + 1))
          printf '%s\n' "$call" > "$MOCK_SS_COUNT_FILE"
          output=$(sed -n "${call}p" "$MOCK_SS_SEQUENCE_FILE")
          [ "$output" = "<absent>" ] || printf '%s\n' "$output"
        else
          printf '%s\n' "${MOCK_SS_OUTPUT-LISTEN 0 5 127.0.0.1:5901 0.0.0.0:*}"
        fi ;;
    esac
    exit 0 ;;
  run)  echo "MOCK_TART_RUN_STDERR_MARKER" >&2; exit 0 ;;  # stderr → tart-up's per-VM log
  *)    exit 0 ;;
esac
TART
chmod +x "$MOCKBIN/tart"

# Mock `nc` (the :22 probe): records its argv, exits $MOCK_NC_RC. tart-up pins
# the probe binary to /usr/bin/nc, so tests must hand it in via $TART_NC_BIN —
# PATH interception never reaches it. The mocked `sleep` below keeps the
# 30-iteration probe loop instant, so the failure path is drivable.
cat > "$MOCKBIN/nc" <<'NC'
#!/usr/bin/env bash
echo "nc $*" >> "$CALLS"
exit "${MOCK_NC_RC:-0}"
NC
chmod +x "$MOCKBIN/nc"

# VNC listener polling waits one second in production. Keep the characterization
# suite instant while recording each requested wait so immediate-failure and
# timeout behavior can be distinguished without wall-clock assertions.
cat > "$MOCKBIN/sleep" <<'SLEEP'
#!/usr/bin/env bash
echo "sleep $*" >> "$CALLS"
exit 0
SLEEP
chmod +x "$MOCKBIN/sleep"

# Mock `ps`: tart_vm_alive runs `ps -axo args=`; emit a `tart run` cmdline for
# it to scan. MOCK_PS_LINE sets the exact line; MOCK_ALIVE=1 emits the
# canonical shape for $MOCK_VM.
cat > "$MOCKBIN/ps" <<'PS'
#!/usr/bin/env bash
if [ -n "${MOCK_PS_LINE:-}" ]; then
  printf '%s\n' "$MOCK_PS_LINE"
elif [ "${MOCK_ALIVE:-0}" = "1" ]; then
  printf '%s\n' "/opt/tart.app/Contents/MacOS/tart run ${MOCK_VM:-app-a} --no-graphics"
fi
exit 0
PS
chmod +x "$MOCKBIN/ps"

# Mock `system_profiler`: the default fixture is a main display whose native
# 3840px width is twice its logical 1920pt width. Failure and custom-JSON knobs
# drive display-scale fallback without depending on the test host's displays.
cat > "$MOCKBIN/system_profiler" <<'SYSTEM_PROFILER'
#!/usr/bin/env bash
echo "system_profiler $*" >> "$CALLS"
[ "${MOCK_SYSTEM_PROFILER_RC:-0}" -eq 0 ] || exit "${MOCK_SYSTEM_PROFILER_RC}"
if [ "${MOCK_SYSTEM_PROFILER_JSON+x}" = x ]; then
  printf '%s\n' "$MOCK_SYSTEM_PROFILER_JSON"
else
  printf '%s\n' '{"SPDisplaysDataType":[{"spdisplays_ndrvs":[{"spdisplays_main":"spdisplays_yes","_spdisplays_pixels":"3840 x 2160","_spdisplays_resolution":"1920 x 1080 @ 60.00Hz"}]}]}'
fi
SYSTEM_PROFILER
chmod +x "$MOCKBIN/system_profiler"

# Run tart-up with the mocks prepended (real jq/seq/etc. stay on PATH).
# Knobs arrive as env on the call: MOCK_LIST_VM (default app-a), MOCK_ALIVE
# (default 1 — a listed-running VM has a live process), MOCK_TART_LIST_RC,
# MOCK_NC_RC, MOCK_SS_OUTPUT, MOCK_SS_SEQUENCE_FILE, MOCK_SS_READ_FAIL,
# MOCK_TART_EXEC_FAIL_MATCH, MOCK_TART_FAIL_MATCH, MOCK_SYSTEM_PROFILER_RC,
# MOCK_SYSTEM_PROFILER_JSON, TART_DISPLAY_SCALE, and RUNUP_LOG_DIR. Exit code
# lands in $rc, stderr in $ERR, recorded mock calls in $CALLS. The sequenced
# listener counter is reset for every invocation.
runup() { # <state> <hostname> <netpolicy-file> <mounts-file> <gui-file> <tart-up argv...>
  local state="$1" hostname="$2" netpolicy="$3" mounts="$4" gui="$5"
  shift 5
  : > "$CALLS"; : > "$SS_COUNT"; rc=0
  PATH="$MOCKBIN:$PATH" HOME="$SANDBOX_HOME" MOCK_VM="${MOCK_LIST_VM:-app-a}" MOCK_STATE="$state" MOCK_IP="${MOCK_IP-10.0.0.9}" MOCK_HOSTNAME="$hostname" \
    MOCK_ALIVE="${MOCK_ALIVE-1}" MOCK_TART_LIST_RC="${MOCK_TART_LIST_RC-0}" MOCK_NC_RC="${MOCK_NC_RC-0}" \
    MOCK_SS_OUTPUT="${MOCK_SS_OUTPUT-LISTEN 0 5 127.0.0.1:5901 0.0.0.0:*}" \
    MOCK_SS_SEQUENCE_FILE="${MOCK_SS_SEQUENCE_FILE-}" MOCK_SS_COUNT_FILE="$SS_COUNT" \
    MOCK_SS_READ_FAIL="${MOCK_SS_READ_FAIL-0}" \
    MOCK_TART_EXEC_FAIL_MATCH="${MOCK_TART_EXEC_FAIL_MATCH-}" \
    MOCK_TART_FAIL_MATCH="${MOCK_TART_FAIL_MATCH-}" \
    TART_NC_BIN="$MOCKBIN/nc" TART_NETPOLICY="$netpolicy" TART_MOUNTS="$mounts" TART_GUI="$gui" \
    TART_LOG_DIR="${RUNUP_LOG_DIR:-$WORK/logs}" \
    bash "$BIN/tart-up" "$@" >/dev/null 2>"$ERR" || rc=$?
  # The stopped-VM `tart run` is backgrounded (& disown), so wait for the mock to
  # log it. The loop exits the moment the line lands; the bound is generous
  # because a loaded machine has been seen to need more than a second.
  if [ "$rc" -eq 0 ] && [ "$state" = stopped ]; then
    local _; for _ in $(seq 1 100); do grep -q 'tart run' "$CALLS" 2>/dev/null && break; sleep 0.1; done
  fi
}

# argument count
check_rc "no args → exit 64"  64 env PATH="$MOCKBIN:$PATH" bash "$BIN/tart-up"
check_rc "two args → exit 64" 64 env PATH="$MOCKBIN:$PATH" bash "$BIN/tart-up" a b
check_rc "bare --gui → exit 64" 64 env PATH="$MOCKBIN:$PATH" bash "$BIN/tart-up" --gui app-a
check_rc "unknown --gui value → exit 64" 64 env PATH="$MOCKBIN:$PATH" bash "$BIN/tart-up" --gui=bogus app-a

# A bare miss has no alias alternative: report only the supplied name and do
# not repeat the list query.
MOCK_LIST_VM=other runup stopped app-a "$EMPTY" "$EMPTY" "$EMPTY" app-a
assert_rc       "bare unknown VM → exit 1" 1
assert_contains "bare unknown VM → diagnostic names supplied form" "$(cat "$ERR")" "VM 'app-a' not found."
assert_absent   "bare unknown VM → diagnostic does not claim another try" "$(cat "$ERR")" "also tried"
assert_eq       "bare unknown VM → one list query" 1 "$(grep -c 'tart list' "$CALLS")"

# A VM literally named in the reserved SSH-alias namespace may exist if raw
# tart created it, but a bare miss must neither retry nor act on that VM.
MOCK_LIST_VM=tart-app-a runup stopped app-a "$EMPTY" "$EMPTY" "$EMPTY" app-a
assert_rc       "bare miss with literal tart-app-a present → exit 1" 1
assert_eq       "bare miss with literal tart-app-a present → no alias probe" 1 "$(grep -c 'tart list' "$CALLS")"
assert_absent   "bare miss with literal tart-app-a present → no tart run" "$(cat "$CALLS")" "tart run tart-app-a"

# The prefix is stripped before the only lookup, so a missing alias reports the
# stored form that was actually checked, in one query.
MOCK_LIST_VM=other runup stopped app-a "$EMPTY" "$EMPTY" "$EMPTY" tart-app-a
assert_rc       "unknown prefixed VM → exit 1" 1
assert_contains "unknown prefixed VM → diagnostic names the stored form" "$(cat "$ERR")" "VM 'app-a' not found."
assert_absent   "unknown prefixed VM → claims no second form" "$(cat "$ERR")" "also tried"
assert_contains "unknown prefixed VM → create hint uses bare name" "$(cat "$ERR")" "tart-new app-a <stack> <distro>"
assert_eq       "unknown prefixed VM → one list query" 1 "$(grep -c 'tart list' "$CALLS")"

# a failing `tart list` is a broken tool, not a missing VM: named diagnostic
# with tart's own stderr surfaced, no stripped-name retry, and no VM start.
MOCK_TART_LIST_RC=1 runup stopped app-a "$EMPTY" "$EMPTY" "$EMPTY" app-a
assert_rc       "tart list failure → exit 1" 1
assert_contains "tart list failure → diagnostic names the tool" "$(cat "$ERR")" "'tart list' failed"
assert_contains "tart list failure → tart's stderr surfaced"    "$(cat "$ERR")" "MOCK_TART_LIST_STDERR_MARKER"
assert_absent   "tart list failure → no tart run"          "$(cat "$CALLS")" "tart run"
assert_eq       "tart list failure → no stripped-name retry" 1 "$(grep -c 'tart list' "$CALLS")"

# base image refusal (a stack clone-source is not a dev VM)
check_rc "base image (fedora-php) → exit 1" 1 \
  env PATH="$MOCKBIN:$PATH" MOCK_VM=fedora-php MOCK_STATE=stopped TART_NC_BIN="$MOCKBIN/nc" \
  TART_NETPOLICY="$EMPTY" TART_MOUNTS="$EMPTY" TART_GUI="$EMPTY" \
  bash "$BIN/tart-up" fedora-php

# stopped → `tart run` carries the netpolicy + mount flags; the probe goes
# through $TART_NC_BIN (the recorded `nc` call proves the seam is honored).
NETP="$WORK/netpolicy"; printf -- '--net-softnet=@host-only\n' > "$NETP"
MNTS="$WORK/mounts";    printf -- '* /srv/data:ro\n'           > "$MNTS"
runup stopped app-a "$NETP" "$MNTS" "$EMPTY" app-a
calls="$(cat "$CALLS")"
assert_contains "stopped → tart run --no-graphics"      "$calls" "tart run app-a --no-graphics"
assert_contains "stopped → run carries netpolicy flag"  "$calls" "--net-softnet=@host-only"
assert_contains "stopped → run carries dir-mount flag"  "$calls" "--dir=data:/srv/data:ro"
assert_contains "stopped → :22 probe uses \$TART_NC_BIN" "$calls" "nc -z -G 3 10.0.0.9 22"
assert_contains "stopped → provisions over vsock (hostname probe)" "$calls" "hostname -s"
# Host keys belong to the image's first-boot oneshot, which runs before sshd ever
# starts. Pinned as a count, not as the absence of a spelling: the property is
# that a started boot spends exactly one vsock call — the hostname probe — so any
# added `tart exec`, however written, shows up here.
assert_eq       "stopped → exactly one provisioning vsock call" 1 "$(grep -c '^tart exec ' "$CALLS")"
assert_absent   "stopped → no host-side host-key regeneration" "$calls" "ssh_host_"

# A selector outside the documented grammar matched nothing and was silently a
# non-match, so the VM started without the share — and work written to the
# expected path in the guest dies with the clone. The forwards parser already
# validates the same grammar; this is the mounts plane catching up.
printf -- 'app-* /srv/data\n' > "$WORK/mounts-badpattern"
runup stopped app-a "$EMPTY" "$WORK/mounts-badpattern" "$EMPTY" app-a
assert_rc       "unsupported mounts selector → VM still starts" 0
assert_contains "unsupported selector is named"        "$(cat "$ERR")" "selector 'app-*' is not"
assert_contains "unsupported selector says the mount is dropped" "$(cat "$ERR")" "NOT attached"
assert_absent   "unsupported selector attaches no --dir" "$(cat "$CALLS")" "--dir="
# A comma list with one bad element is refused as a whole, not partially applied.
printf -- 'app-a,app-* /srv/data\n' > "$WORK/mounts-badlist"
runup stopped app-a "$EMPTY" "$WORK/mounts-badlist" "$EMPTY" app-a
assert_absent   "a comma list with a bad element attaches nothing" "$(cat "$CALLS")" "--dir="
# The documented forms still work. `*` is the wildcard on its own only — inside a
# comma list it is not a valid element, which is why the list below spells names.
printf -- 'app-a /srv/one\napp-a,other /srv/two\n* /srv/three\n' > "$WORK/mounts-good"
runup stopped app-a "$EMPTY" "$WORK/mounts-good" "$EMPTY" app-a
assert_contains "an exact-name selector still attaches"  "$(cat "$CALLS")" "--dir=one:/srv/one"
assert_contains "a comma list of names still attaches"   "$(cat "$CALLS")" "--dir=two:/srv/two"
assert_contains "the bare wildcard still attaches"       "$(cat "$CALLS")" "--dir=three:/srv/three"

# An unreadable mounts file fails closed like the gui plane: a VM missing its
# shares is indistinguishable from one that has them until something reads an
# empty /mnt/shared.
chmod 000 "$MNTS"
runup stopped app-a "$EMPTY" "$MNTS" "$EMPTY" app-a
assert_rc       "unreadable mounts file → exit 1" 1
assert_contains "unreadable mounts file → names readability" "$(cat "$ERR")" "file exists but is not readable"
assert_contains "unreadable mounts file → uses fail-closed voice" "$(cat "$ERR")" "refusing to start"
assert_absent   "unreadable mounts file → refuses boot" "$(cat "$CALLS")" "tart run"
chmod 600 "$MNTS"

# tart's own stderr is captured to a per-VM log (truncate-on-start) so a crash's
# `fixme:` line survives; the mock `tart run` emits a stderr marker.
runlog="$WORK/logs/app-a.run.log"
for _ in $(seq 1 20); do [ -s "$runlog" ] && break; sleep 0.1; done
assert_contains "stopped → tart run stderr captured to per-VM log" "$(cat "$runlog" 2>/dev/null)" "MOCK_TART_RUN_STDERR_MARKER"

# an unusable log target must never block the start (the redirect degrades to
# /dev/null instead): point TART_LOG_DIR at a regular file.
: > "$WORK/not-a-dir"
RUNUP_LOG_DIR="$WORK/not-a-dir" runup stopped app-a "$EMPTY" "$EMPTY" "$EMPTY" app-a
assert_rc       "log dir is a regular file → still exits 0" 0
assert_contains "log dir is a regular file → VM still starts" "$(cat "$CALLS")" "tart run app-a --no-graphics"

# netpolicy tokens must reach `tart run` argv byte-for-byte: run from a cwd
# holding a file the token WOULD glob-match — expansion would swap the token
# for the filename.
GLOBCWD="$WORK/globcwd"; mkdir -p "$GLOBCWD"
: > "$GLOBCWD/--net-softnet-allow=evil"
printf -- '--net-softnet-allow=*\n' > "$WORK/netpolicy-glob"
( cd "$GLOBCWD" && runup stopped app-a "$WORK/netpolicy-glob" "$EMPTY" "$EMPTY" app-a )
# rc/ERR die with the subshell — assert via $CALLS only.
calls="$(cat "$CALLS")"
assert_contains "netpolicy glob char reaches tart run literally" "$calls" "tart run app-a --no-graphics --net-softnet-allow=*"
assert_absent   "netpolicy token did not expand against the cwd" "$calls" "--net-softnet-allow=evil"

# a non-`--net-*` token is a corrupt or tampered-with policy: refuse to start
# at all (a partially applied policy must never happen) and name the token.
printf -- '--net-softnet --dir=/x\n' > "$WORK/netpolicy-bad"
runup stopped app-a "$WORK/netpolicy-bad" "$EMPTY" "$EMPTY" app-a
assert_rc       "non --net-* netpolicy token → exit 1" 1
assert_contains "netpolicy refusal names the token" "$(cat "$ERR")" "--dir=/x"
assert_absent   "netpolicy refusal → VM not started" "$(cat "$CALLS")" "tart run"

# Gui config is exact-name and single-winner. Comments/blanks are tolerated,
# but every non-comment line is validated even when it names another VM.
GUI_VALID="$WORK/gui-valid"
printf '\n# engine-managed defaults\nother-vm headless\napp-a vnc # desktop\n' > "$GUI_VALID"
runup stopped app-a "$EMPTY" "$EMPTY" "$GUI_VALID" app-a
assert_rc       "gui file valid exact-name line → exit 0" 0
calls="$(cat "$CALLS")"
assert_contains "gui file vnc → headless tart launch" "$calls" "tart run app-a --no-graphics"
assert_contains "gui file vnc → starts VNC on a started boot" "$calls" "sudo systemctl start tart-stacks-vnc.service"
assert_contains "gui file vnc → verifies listener with ss" "$calls" "tart exec app-a ss -tln"
assert_contains "gui file vnc → prints tunnel hint" "$(cat "$ERR")" "ssh -L 5901:127.0.0.1:5901 tart-app-a"
assert_absent   "gui file vnc → no host-window scale detection" "$calls" "system_profiler"
assert_absent   "gui file vnc → no guest display-scale application" "$calls" "tart-stacks-display-scale"

printf '# ok\napp-a sideways\n' > "$WORK/gui-unknown"
runup stopped app-a "$EMPTY" "$EMPTY" "$WORK/gui-unknown" app-a
assert_rc       "unknown gui token → exit 1" 1
assert_contains "unknown gui token → names line 2" "$(cat "$ERR")" "line 2"
assert_absent   "unknown gui token → refuses boot" "$(cat "$CALLS")" "tart run"

printf '# ok\napp-a vnc trailing\n' > "$WORK/gui-extra"
runup stopped app-a "$EMPTY" "$EMPTY" "$WORK/gui-extra" app-a
assert_rc       "extra gui field → exit 1" 1
assert_contains "extra gui field → names line 2" "$(cat "$ERR")" "line 2"
assert_absent   "extra gui field → refuses boot" "$(cat "$CALLS")" "tart run"

printf '# ok\napp-a vnc\napp-a window\n' > "$WORK/gui-duplicate"
runup stopped app-a "$EMPTY" "$EMPTY" "$WORK/gui-duplicate" app-a
assert_rc       "duplicate gui name → exit 1" 1
assert_contains "duplicate gui name → names line 3" "$(cat "$ERR")" "line 3"
assert_absent   "duplicate gui name → refuses boot" "$(cat "$CALLS")" "tart run"

printf '# patterns are corrupt here\n* vnc\n' > "$WORK/gui-pattern"
runup stopped app-a "$EMPTY" "$EMPTY" "$WORK/gui-pattern" app-a
assert_rc       "gui pattern → exit 1" 1
assert_contains "gui pattern → names line 2" "$(cat "$ERR")" "line 2"
assert_contains "gui pattern → explains exact-name grammar" "$(cat "$ERR")" "patterns"
assert_absent   "gui pattern → refuses boot" "$(cat "$CALLS")" "tart run"

printf 'app-a window\n' > "$WORK/gui-unreadable"
chmod 000 "$WORK/gui-unreadable"
runup stopped app-a "$EMPTY" "$EMPTY" "$WORK/gui-unreadable" app-a
assert_rc       "unreadable gui file → exit 1" 1
assert_contains "unreadable gui file → names readability" "$(cat "$ERR")" "file exists but is not readable"
assert_contains "unreadable gui file → uses fail-closed voice" "$(cat "$ERR")" "refusing to start"
assert_absent   "unreadable gui file → refuses boot" "$(cat "$CALLS")" "tart run"
chmod 600 "$WORK/gui-unreadable"

# Argv wins over a valid file line. Window is the sole run shape that omits
# --no-graphics; netpolicy and mounts retain their normal order and spelling.
printf 'app-a vnc\n' > "$WORK/gui-vnc"
runup stopped app-a "$NETP" "$MNTS" "$WORK/gui-vnc" --gui=window app-a
assert_rc       "argv window beats file vnc → exit 0" 0
calls="$(cat "$CALLS")"
assert_contains "window → run keeps netpolicy + mounts" "$calls" "tart run app-a --net-softnet=@host-only --dir=data:/srv/data:ro"
assert_absent   "window → run drops --no-graphics" "$calls" "tart run app-a --no-graphics"
assert_contains "window → detects main-display backing scale" "$calls" "system_profiler -json SPDisplaysDataType"
assert_contains "window → applies detected scale in guest" "$calls" "tart exec app-a /usr/local/bin/tart-stacks-display-scale 2"
assert_contains "window → isolates graphical target on started boot" "$calls" "sudo systemctl isolate graphical.target"
assert_order    "window → applies scale before graphical session starts" \
  "tart exec app-a /usr/local/bin/tart-stacks-display-scale 2" \
  "tart exec app-a sudo systemctl isolate graphical.target"
assert_contains "window → verifies the display manager came up" "$calls" "systemctl is-active --quiet display-manager.service"
assert_absent   "window override → does not start VNC" "$calls" "systemctl start tart-stacks-vnc.service"

runup stopped app-a "$EMPTY" "$EMPTY" "$WORK/gui-vnc" --gui=headless app-a
assert_rc       "argv headless beats file vnc → exit 0" 0
calls="$(cat "$CALLS")"
assert_contains "headless override → tart run --no-graphics" "$calls" "tart run app-a --no-graphics"
assert_absent   "headless override → no window activation" "$calls" "graphical.target"
assert_absent   "headless override → no vnc activation" "$calls" "tart-stacks-vnc.service"
assert_absent   "headless override → no display-scale detection" "$calls" "system_profiler"
assert_absent   "headless override → no display-scale application" "$calls" "tart-stacks-display-scale"

# Scale is cosmetic boot state: detection and guest application failures never
# block the graphical activation. An explicit override bypasses host probing.
MOCK_SYSTEM_PROFILER_RC=1 \
  runup stopped app-a "$EMPTY" "$EMPTY" "$EMPTY" --gui=window app-a
assert_rc       "display-scale detection failure → window still starts" 0
assert_contains "display-scale detection failure → applies safe factor 1" "$(cat "$CALLS")" \
  "tart exec app-a /usr/local/bin/tart-stacks-display-scale 1"

TART_DISPLAY_SCALE=3 \
  runup stopped app-a "$EMPTY" "$EMPTY" "$EMPTY" --gui=window app-a
assert_rc       "display-scale override → window starts" 0
calls="$(cat "$CALLS")"
assert_contains "display-scale override → drives guest factor" "$calls" \
  "tart exec app-a /usr/local/bin/tart-stacks-display-scale 3"
assert_absent   "display-scale override → skips system_profiler" "$calls" "system_profiler"

TART_DISPLAY_SCALE=99 \
  runup stopped app-a "$EMPTY" "$EMPTY" "$EMPTY" --gui=window app-a
assert_rc       "out-of-range display-scale override → window starts" 0
assert_contains "out-of-range display-scale override → clamps to 3" "$(cat "$CALLS")" \
  "tart exec app-a /usr/local/bin/tart-stacks-display-scale 3"

TART_DISPLAY_SCALE=bogus \
  runup stopped app-a "$EMPTY" "$EMPTY" "$EMPTY" --gui=window app-a
assert_rc       "invalid display-scale override → window still starts" 0
assert_contains "invalid display-scale override → warns" "$(cat "$ERR")" "invalid TART_DISPLAY_SCALE 'bogus'"
assert_contains "invalid display-scale override → applies safe factor 1" "$(cat "$CALLS")" \
  "tart exec app-a /usr/local/bin/tart-stacks-display-scale 1"

# A fractional ("More Space") mode divides the panel's pixels by a logical width
# that is not half of them, yet macOS still backs that mode at 2 — so the
# nearest integer is the truthful factor, not a parse failure.
MOCK_SYSTEM_PROFILER_JSON='{"SPDisplaysDataType":[{"spdisplays_ndrvs":[{"spdisplays_main":"spdisplays_yes","_spdisplays_pixels":"3456 x 2234","_spdisplays_resolution":"2056 x 1329 @ 120.00Hz"}]}]}' \
  runup stopped app-a "$EMPTY" "$EMPTY" "$EMPTY" --gui=window app-a
assert_rc       "fractional display mode → window still starts" 0
assert_contains "fractional display mode → rounds to the backing factor" "$(cat "$CALLS")" \
  "tart exec app-a /usr/local/bin/tart-stacks-display-scale 2"

# A panel whose pixels are its points needs no scaling at all.
MOCK_SYSTEM_PROFILER_JSON='{"SPDisplaysDataType":[{"spdisplays_ndrvs":[{"spdisplays_main":"spdisplays_yes","_spdisplays_pixels":"1920 x 1080","_spdisplays_resolution":"1920 x 1080 @ 60.00Hz"}]}]}' \
  runup stopped app-a "$EMPTY" "$EMPTY" "$EMPTY" --gui=window app-a
assert_rc       "non-Retina main display → window starts" 0
assert_contains "non-Retina main display → applies unscaled factor 1" "$(cat "$CALLS")" \
  "tart exec app-a /usr/local/bin/tart-stacks-display-scale 1"

# With no display flagged main there is no window backing scale to read; a
# secondary's is not a stand-in for it.
MOCK_SYSTEM_PROFILER_JSON='{"SPDisplaysDataType":[{"spdisplays_ndrvs":[{"_spdisplays_pixels":"3840 x 2160","_spdisplays_resolution":"1920 x 1080 @ 60.00Hz"}]}]}' \
  runup stopped app-a "$EMPTY" "$EMPTY" "$EMPTY" --gui=window app-a
assert_rc       "no main display → window still starts" 0
assert_contains "no main display → applies safe factor 1" "$(cat "$CALLS")" \
  "tart exec app-a /usr/local/bin/tart-stacks-display-scale 1"

TART_DISPLAY_SCALE=2 \
MOCK_TART_EXEC_FAIL_MATCH="/usr/local/bin/tart-stacks-display-scale 2" \
  runup stopped app-a "$EMPTY" "$EMPTY" "$EMPTY" --gui=window app-a
assert_rc       "display-scale apply failure → window still starts" 0
assert_contains "display-scale apply failure → warns" "$(cat "$ERR")" "could not apply display scale '2'"
assert_contains "display-scale apply failure → still isolates graphical target" "$(cat "$CALLS")" \
  "sudo systemctl isolate graphical.target"

# Started activation fails loud while leaving the VM process up. A VNC bind
# outside loopback is actively shut down because the unit uses no VNC auth.
MOCK_TART_EXEC_FAIL_MATCH="sudo systemctl isolate graphical.target" \
  runup stopped app-a "$EMPTY" "$EMPTY" "$EMPTY" --gui=window app-a
assert_rc       "window activation failure → exit 1" 1
assert_contains "window activation failure → named error" "$(cat "$ERR")" "window gui activation failed"

# graphical.target only Wants= the DM: the isolate can succeed with no desktop
# (non-GUI clone, failed DM). The DM-active verify is what makes window mode
# honest about showing one.
MOCK_TART_EXEC_FAIL_MATCH="systemctl is-active --quiet display-manager.service" \
  runup stopped app-a "$EMPTY" "$EMPTY" "$EMPTY" --gui=window app-a
assert_rc       "window DM never active → exit 1" 1
assert_contains "window DM never active → names the DM verify" "$(cat "$ERR")" "display-manager.service did not become active"
assert_eq       "window DM never active → bounded poll" 15 "$(grep -c 'tart exec app-a systemctl is-active --quiet display-manager.service' "$CALLS")"

MOCK_TART_EXEC_FAIL_MATCH="sudo systemctl start tart-stacks-vnc.service" \
  runup stopped app-a "$EMPTY" "$EMPTY" "$EMPTY" --gui=vnc app-a
assert_rc       "vnc activation failure → exit 1" 1
assert_contains "vnc activation failure → named error" "$(cat "$ERR")" "vnc gui activation failed"

SS_SEQUENCE="$WORK/ss-sequence"
printf '<absent>\nLISTEN 0 5 127.0.0.1:5901 0.0.0.0:*\n' > "$SS_SEQUENCE"
MOCK_SS_SEQUENCE_FILE="$SS_SEQUENCE" \
  runup stopped app-a "$EMPTY" "$EMPTY" "$EMPTY" --gui=vnc app-a
assert_rc       "vnc delayed bind → exit 0" 0
assert_eq       "vnc delayed bind → probes until listener appears" 2 "$(grep -c 'tart exec app-a ss -tln' "$CALLS")"
assert_eq       "vnc delayed bind → waits after the absent probe" 1 "$(grep -c '^sleep 1$' "$CALLS")"
assert_contains "vnc delayed bind → prints tunnel hint" "$(cat "$ERR")" "VNC ready"

MOCK_SS_OUTPUT="LISTEN 0 5 127.0.0.1:5901 0.0.0.0:*${nl:-$'\n'}LISTEN 0 5 0.0.0.0:5901 0.0.0.0:*" \
  runup stopped app-a "$EMPTY" "$EMPTY" "$EMPTY" --gui=vnc app-a
assert_rc       "vnc wildcard listener → exit 1" 1
assert_contains "vnc wildcard listener → names unsafe bind" "$(cat "$ERR")" "0.0.0.0:5901"
assert_contains "vnc wildcard listener → stops unauthenticated service" "$(cat "$CALLS")" "sudo systemctl stop tart-stacks-vnc.service"
assert_eq       "vnc wildcard listener → fails on first probe" 1 "$(grep -c 'tart exec app-a ss -tln' "$CALLS")"
assert_eq       "vnc wildcard listener → does not wait" 0 "$(grep -c '^sleep 1$' "$CALLS")"

MOCK_SS_OUTPUT="" runup stopped app-a "$EMPTY" "$EMPTY" "$EMPTY" --gui=vnc app-a
assert_rc       "vnc never binds → exit 1" 1
assert_contains "vnc never binds → names 30-second timeout" "$(cat "$ERR")" "timed out after 30 seconds"
assert_eq       "vnc never binds → probes 30 times" 30 "$(grep -c 'tart exec app-a ss -tln' "$CALLS")"
assert_eq       "vnc never binds → waits 30 one-second intervals" 30 "$(grep -c '^sleep 1$' "$CALLS")"

SS_SEQUENCE_V6="$WORK/ss-sequence-v6"
printf 'LISTEN 0 5 [::1]:5901 [::]:*\nLISTEN 0 5 127.0.0.1:5901 0.0.0.0:*\n' > "$SS_SEQUENCE_V6"
MOCK_SS_SEQUENCE_FILE="$SS_SEQUENCE_V6" \
  runup stopped app-a "$EMPTY" "$EMPTY" "$EMPTY" --gui=vnc app-a
assert_rc       "vnc v6-only bind → polls for the v4 listener" 0
assert_eq       "vnc v6-only bind → second probe found v4" 2 "$(grep -c 'tart exec app-a ss -tln' "$CALLS")"

MOCK_SS_OUTPUT="LISTEN 0 5 [::1]:5901 [::]:*" \
  runup stopped app-a "$EMPTY" "$EMPTY" "$EMPTY" --gui=vnc app-a
assert_rc       "vnc v6-only forever → exit 1 (tunnel targets 127.0.0.1)" 1
assert_contains "vnc v6-only forever → names the 127.0.0.1:5901 wait" "$(cat "$ERR")" "127.0.0.1:5901 listener"

MOCK_SS_READ_FAIL=1 runup stopped app-a "$EMPTY" "$EMPTY" "$EMPTY" --gui=vnc app-a
assert_rc       "vnc listener-table read failure → exit 1" 1
assert_contains "vnc listener-table read failure → named error" "$(cat "$ERR")" "could not read the guest TCP listener table"
assert_eq       "vnc listener-table read failure → does not wait" 0 "$(grep -c '^sleep 1$' "$CALLS")"

MOCK_SS_OUTPUT="LISTEN 0 5 0.0.0.0:5901 0.0.0.0:*" \
MOCK_TART_EXEC_FAIL_MATCH="sudo systemctl stop tart-stacks-vnc.service" \
  runup stopped app-a "$EMPTY" "$EMPTY" "$EMPTY" --gui=vnc app-a
assert_rc       "vnc unsafe + unit stop failure → exit 1" 1
assert_contains "vnc unsafe + unit stop failure → stops VM" "$(cat "$CALLS")" "tart stop app-a"
assert_contains "vnc unsafe + unit stop failure → explains escalation" "$(cat "$ERR")" "stopped VM 'app-a'"

MOCK_SS_OUTPUT="LISTEN 0 5 0.0.0.0:5901 0.0.0.0:*" \
MOCK_TART_EXEC_FAIL_MATCH="sudo systemctl stop tart-stacks-vnc.service" \
MOCK_TART_FAIL_MATCH="stop app-a" \
  runup stopped app-a "$EMPTY" "$EMPTY" "$EMPTY" --gui=vnc app-a
assert_rc       "vnc unsafe + all cleanup failure → exit 1" 1
assert_contains "vnc unsafe + all cleanup failure → names both failures" "$(cat "$ERR")" "FAILED to stop tart-stacks-vnc.service and FAILED to stop VM 'app-a'"

# A [::1]-only bind is loopback-safe but unusable by the advertised
# 127.0.0.1:5901 tunnel, so it is treated as absent (poll grace), never ok —
# and never unsafe either: the service is not exposed, so it is not stopped
# mid-wait; only the timeout path shuts it down.
MOCK_SS_OUTPUT="LISTEN 0 5 [::1]:5901 [::]:*${nl:-$'\n'}LISTEN 0 5 127.0.0.1:5901 0.0.0.0:*" \
  runup stopped app-a "$EMPTY" "$EMPTY" "$EMPTY" --gui=vnc app-a
assert_rc       "vnc v6+v4 loopback listeners → exit 0" 0
assert_absent   "vnc v6+v4 loopback listeners → service stays up" "$(cat "$CALLS")" "sudo systemctl stop tart-stacks-vnc.service"

# running + alive → no `tart run`, AND no guest-agent provisioning: an
# already-up VM was provisioned on the boot that started it, and each
# `tart exec` is a guest-vsock connect — the exact call that trips the Apple
# Virtualization.framework trap and crashes the VM. The mounts notice is the
# positive signal anchoring the absence checks: tart-up got past the liveness
# gate rather than dying early.
runup running app-a "$EMPTY" "$MNTS" "$WORK/gui-vnc" app-a
assert_rc       "running+alive → exit 0" 0
assert_contains "running+alive → mounts attach-at-boot notice" "$(cat "$ERR")" "configured mount(s) attach at boot"
assert_contains "running+alive → gui applies-at-boot notice" "$(cat "$ERR")" "gui mode 'vnc' applies at boot"
calls="$(cat "$CALLS")"
assert_absent "running → no tart run issued"        "$calls" "tart run"
assert_absent "running → no provisioning vsock hit" "$calls" "hostname -s"
assert_absent "running vnc → no activation vsock hit" "$calls" "tart-stacks-vnc.service"

runup running app-a "$EMPTY" "$EMPTY" "$EMPTY" --gui=window app-a
assert_rc       "running window → warns and exits 0" 0
assert_contains "running window → gui applies-at-boot notice" "$(cat "$ERR")" "gui mode 'window' applies at boot"
assert_absent   "running window → no activation vsock hit" "$(cat "$CALLS")" "graphical.target"
assert_absent   "running window → no display-scale detection" "$(cat "$CALLS")" "system_profiler"
assert_absent   "running window → no display-scale application" "$(cat "$CALLS")" "tart-stacks-display-scale"

# listed "running" with no live `tart run` process is the wedged-crash
# signature: fail fast with the remedy instead of polling a ghost for minutes.
MOCK_ALIVE=0 runup running app-a "$EMPTY" "$EMPTY" "$EMPTY" app-a
assert_rc       "wedged (running, no process) → exit 1" 1
assert_contains "wedge diagnostic names the remedy" "$(cat "$ERR")" "tart stop app-a"
assert_absent   "wedged → no tart run issued" "$(cat "$CALLS")" "tart run"

# hostname branch: a mismatch sets it; an already-correct hostname leaves it
runup stopped wrong-name "$EMPTY" "$EMPTY" "$EMPTY" app-a
assert_contains "hostname mismatch → set-hostname" "$(cat "$CALLS")" "hostnamectl set-hostname app-a"
runup stopped app-a "$EMPTY" "$EMPTY" "$EMPTY" app-a
assert_absent "hostname already correct → no set-hostname" "$(cat "$CALLS")" "set-hostname"

# prefix lookup: stored bare `app-a`, asked as `tart-app-a`
runup stopped app-a "$EMPTY" "$EMPTY" "$EMPTY" tart-app-a
assert_contains "prefix lookup tart-app-a → app-a" "$(cat "$CALLS")" "tart run app-a --no-graphics"

# Boot diagnostics: the two messages an operator actually reads when a start
# goes wrong. Both sit behind polling loops, so each also pins that the loop ran
# to its bound rather than falling through early on the first miss.
MOCK_IP='' runup stopped app-a "$EMPTY" "$EMPTY" "$EMPTY" app-a
assert_rc       "no DHCP lease → exit 1" 1
assert_contains "no-IP diagnostic names the VM and the window" "$(cat "$ERR")" "did not get an IP within 60 s"
assert_eq       "no-IP path polls its full 60 intervals" 60 "$(grep -c '^sleep 1$' "$CALLS")"
assert_absent   "no-IP path never probes :22" "$(cat "$CALLS")" "nc "
# The launch is detached, so a `tart run` that failed outright is indistinguishable
# from slow DHCP here — its real error only exists in the log.
assert_contains "no-IP diagnostic names this boot's run log" "$(cat "$ERR")" "app-a.run.log"

MOCK_NC_RC=1 runup stopped app-a "$EMPTY" "$EMPTY" "$EMPTY" app-a
assert_rc       "sshd never accepts on :22 → exit 1" 1
assert_contains "ssh-timeout diagnostic names VM and IP" "$(cat "$ERR")" "app-a (10.0.0.9) did not accept SSH on :22 in time"
assert_eq       "ssh probe retries its full 30 intervals" 30 "$(grep -c '^nc -z -G 3 10.0.0.9 22$' "$CALLS")"
assert_contains "ssh-timeout diagnostic names this boot's run log" "$(cat "$ERR")" "app-a.run.log"

# A boot this invocation did not start has no log of its own — the file is
# truncated per `tart run`, so naming it would point at another boot.
MOCK_NC_RC=1 runup running app-a "$EMPTY" "$EMPTY" "$EMPTY" app-a
assert_rc       "already-running VM unreachable on :22 → exit 1" 1
assert_absent   "already-running VM's timeout names no run log" "$(cat "$ERR")" "run.log"

printf '\n  %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
