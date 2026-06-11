#!/usr/bin/env bash
# Characterization tests for bin/tart-up's runtime flow — no real VM, no real
# sleeps. Mocked `tart` (list/run/ip/exec; `list` fails on demand via
# MOCK_TART_LIST_RC), `nc` (logs its argv, exits $MOCK_NC_RC; reached through
# the $TART_NC_BIN seam, not PATH) and `ps` (MOCK_PS_LINE/MOCK_ALIVE fake the
# `tart run` cmdline the liveness scan reads) make the IP poll and the :22
# probe converge on the first iteration. Covers resolve + prefix lookup, the
# tart-list failure path, base-image refusal, the stopped→`tart run` command
# (netpolicy gating + mount flags + stderr log capture), the running-VM paths
# (alive vs wedged), and the hostname-set branch. Plain bash, no framework.
# Run via script/test or directly.
set -uo pipefail

TEST_DIR=$(cd -P "$(dirname "$0")" >/dev/null 2>&1 && pwd)
REPO=$(cd -P "$TEST_DIR/.." >/dev/null 2>&1 && pwd)
BIN="$REPO/bin"

pass=0 fail=0
ok()  { pass=$((pass + 1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  FAIL %s\n         %s\n' "$1" "$2"; }
assert_eq()       { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "want » $2 « got » $3 «"; fi; }
assert_contains() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "want » $3 « in: $2" ;; esac; }
assert_absent()   { case "$2" in *"$3"*) bad "$1" "should NOT contain » $3 «" ;; *) ok "$1" ;; esac; }
check_rc() { local l="$1" want="$2"; shift 2; local got=0; "$@" >/dev/null 2>&1 || got=$?
  if [ "$got" -eq "$want" ]; then ok "$l"; else bad "$l" "want rc=$want got rc=$got"; fi; }
assert_rc() { # label want — checks $rc from the last runup
  if [ "$rc" -eq "$2" ]; then ok "$1"; else bad "$1" "want rc=$2 got rc=$rc"; fi; }

WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
MOCKBIN="$WORK/bin"; mkdir -p "$MOCKBIN"
CALLS="$WORK/calls"; export CALLS
ERR="$WORK/stderr"
EMPTY="$WORK/empty"; : > "$EMPTY"

# Mock `tart`: `list` emits one VM (name=$MOCK_VM, state=$MOCK_STATE), or —
# with MOCK_TART_LIST_RC nonzero — prints a stderr marker and fails with that
# rc; `ip` returns $MOCK_IP; `exec <vm> hostname -s` returns $MOCK_HOSTNAME
# (drives the set-hostname branch); `run` and any other `exec` just record.
# Every call is logged to $CALLS.
cat > "$MOCKBIN/tart" <<'TART'
#!/usr/bin/env bash
echo "tart $*" >> "$CALLS"
case "$1" in
  list)
    if [ "${MOCK_TART_LIST_RC:-0}" -ne 0 ]; then
      echo "MOCK_TART_LIST_STDERR_MARKER" >&2
      exit "${MOCK_TART_LIST_RC}"
    fi
    printf '[{"Name":"%s","State":"%s"}]\n' "${MOCK_VM:-app-a}" "${MOCK_STATE:-stopped}" ;;
  ip)   printf '%s\n' "${MOCK_IP:-10.0.0.9}" ;;
  exec) shift 2; [ "$*" = "hostname -s" ] && printf '%s\n' "${MOCK_HOSTNAME:-app-a}"; exit 0 ;;
  run)  echo "MOCK_TART_RUN_STDERR_MARKER" >&2; exit 0 ;;  # stderr → tart-up's per-VM log
  *)    exit 0 ;;
esac
TART
chmod +x "$MOCKBIN/tart"

# Mock `nc` (the :22 probe): records its argv, exits $MOCK_NC_RC. tart-up pins
# the probe binary to /usr/bin/nc, so tests must hand it in via $TART_NC_BIN —
# PATH interception never reaches it. (MOCK_NC_RC states the mock's contract;
# the probe-failure path costs ~30 real seconds, so no test drives it.)
cat > "$MOCKBIN/nc" <<'NC'
#!/usr/bin/env bash
echo "nc $*" >> "$CALLS"
exit "${MOCK_NC_RC:-0}"
NC
chmod +x "$MOCKBIN/nc"

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

# Run tart-up with the mocks prepended (real jq/seq/sleep/etc. stay on PATH).
# Knobs arrive as env on the call: MOCK_ALIVE (default 1 — a listed-running VM
# has a live process), MOCK_TART_LIST_RC, MOCK_NC_RC, RUNUP_LOG_DIR. Exit code
# lands in $rc, stderr in $ERR, recorded mock calls in $CALLS.
runup() { # <state> <hostname> <netpolicy-file> <mounts-file> <vm-arg>
  : > "$CALLS"; rc=0
  PATH="$MOCKBIN:$PATH" MOCK_VM=app-a MOCK_STATE="$1" MOCK_IP=10.0.0.9 MOCK_HOSTNAME="$2" \
    MOCK_ALIVE="${MOCK_ALIVE-1}" MOCK_TART_LIST_RC="${MOCK_TART_LIST_RC-0}" MOCK_NC_RC="${MOCK_NC_RC-0}" \
    TART_NC_BIN="$MOCKBIN/nc" TART_NETPOLICY="$3" TART_MOUNTS="$4" \
    TART_LOG_DIR="${RUNUP_LOG_DIR:-$WORK/logs}" \
    bash "$BIN/tart-up" "$5" >/dev/null 2>"$ERR" || rc=$?
  # The stopped-VM `tart run` is backgrounded (& disown); give the mock up to ~2s to log it.
  if [ "$rc" -eq 0 ] && [ "$1" = stopped ]; then
    local _; for _ in $(seq 1 20); do grep -q 'tart run' "$CALLS" 2>/dev/null && break; sleep 0.1; done
  fi
}

# argument count
check_rc "no args → exit 64"  64 env PATH="$MOCKBIN:$PATH" bash "$BIN/tart-up"
check_rc "two args → exit 64" 64 env PATH="$MOCKBIN:$PATH" bash "$BIN/tart-up" a b

# unknown VM (mock lists a different name) → exit 1
check_rc "unknown VM → exit 1" 1 \
  env PATH="$MOCKBIN:$PATH" MOCK_VM=other MOCK_STATE=stopped TART_NC_BIN="$MOCKBIN/nc" \
  TART_NETPOLICY="$EMPTY" TART_MOUNTS="$EMPTY" \
  bash "$BIN/tart-up" app-a

# a failing `tart list` is a broken tool, not a missing VM: named diagnostic
# with tart's own stderr surfaced, no prefix-swap retry, and no VM start.
MOCK_TART_LIST_RC=1 runup stopped app-a "$EMPTY" "$EMPTY" app-a
assert_rc       "tart list failure → exit 1" 1
assert_contains "tart list failure → diagnostic names the tool" "$(cat "$ERR")" "'tart list' failed"
assert_contains "tart list failure → tart's stderr surfaced"    "$(cat "$ERR")" "MOCK_TART_LIST_STDERR_MARKER"
assert_absent   "tart list failure → no tart run"          "$(cat "$CALLS")" "tart run"
assert_eq       "tart list failure → no prefix-swap retry" 1 "$(grep -c 'tart list' "$CALLS")"

# base image refusal (a stack clone-source is not a dev VM)
check_rc "base image (fedora-php) → exit 1" 1 \
  env PATH="$MOCKBIN:$PATH" MOCK_VM=fedora-php MOCK_STATE=stopped TART_NC_BIN="$MOCKBIN/nc" \
  TART_NETPOLICY="$EMPTY" TART_MOUNTS="$EMPTY" \
  bash "$BIN/tart-up" fedora-php

# stopped → `tart run` carries the netpolicy + mount flags; the probe goes
# through $TART_NC_BIN (the recorded `nc` call proves the seam is honored).
NETP="$WORK/netpolicy"; printf -- '--net-softnet=@host-only\n' > "$NETP"
MNTS="$WORK/mounts";    printf -- '* /srv/data:ro\n'           > "$MNTS"
runup stopped app-a "$NETP" "$MNTS" app-a
calls="$(cat "$CALLS")"
assert_contains "stopped → tart run --no-graphics"      "$calls" "tart run app-a --no-graphics"
assert_contains "stopped → run carries netpolicy flag"  "$calls" "--net-softnet=@host-only"
assert_contains "stopped → run carries dir-mount flag"  "$calls" "--dir=data:/srv/data:ro"
assert_contains "stopped → :22 probe uses \$TART_NC_BIN" "$calls" "nc -z -G 3 10.0.0.9 22"
assert_contains "stopped → provisions over vsock (hostname probe)" "$calls" "hostname -s"

# tart's own stderr is captured to a per-VM log (truncate-on-start) so a crash's
# `fixme:` line survives; the mock `tart run` emits a stderr marker.
runlog="$WORK/logs/app-a.run.log"
for _ in $(seq 1 20); do [ -s "$runlog" ] && break; sleep 0.1; done
assert_contains "stopped → tart run stderr captured to per-VM log" "$(cat "$runlog" 2>/dev/null)" "MOCK_TART_RUN_STDERR_MARKER"

# an unusable log target must never block the start (the redirect degrades to
# /dev/null instead): point TART_LOG_DIR at a regular file.
: > "$WORK/not-a-dir"
RUNUP_LOG_DIR="$WORK/not-a-dir" runup stopped app-a "$EMPTY" "$EMPTY" app-a
assert_rc       "log dir is a regular file → still exits 0" 0
assert_contains "log dir is a regular file → VM still starts" "$(cat "$CALLS")" "tart run app-a --no-graphics"

# netpolicy tokens must reach `tart run` argv byte-for-byte: run from a cwd
# holding a file the token WOULD glob-match — expansion would swap the token
# for the filename.
GLOBCWD="$WORK/globcwd"; mkdir -p "$GLOBCWD"
: > "$GLOBCWD/--net-softnet-allow=evil"
printf -- '--net-softnet-allow=*\n' > "$WORK/netpolicy-glob"
( cd "$GLOBCWD" && runup stopped app-a "$WORK/netpolicy-glob" "$EMPTY" app-a )
# rc/ERR die with the subshell — assert via $CALLS only.
calls="$(cat "$CALLS")"
assert_contains "netpolicy glob char reaches tart run literally" "$calls" "tart run app-a --no-graphics --net-softnet-allow=*"
assert_absent   "netpolicy token did not expand against the cwd" "$calls" "--net-softnet-allow=evil"

# a non-`--net-*` token is a corrupt or tampered-with policy: refuse to start
# at all (a partially applied policy must never happen) and name the token.
printf -- '--net-softnet --dir=/x\n' > "$WORK/netpolicy-bad"
runup stopped app-a "$WORK/netpolicy-bad" "$EMPTY" app-a
assert_rc       "non --net-* netpolicy token → exit 1" 1
assert_contains "netpolicy refusal names the token" "$(cat "$ERR")" "--dir=/x"
assert_absent   "netpolicy refusal → VM not started" "$(cat "$CALLS")" "tart run"

# running + alive → no `tart run`, AND no guest-agent provisioning: an
# already-up VM was provisioned on the boot that started it, and each
# `tart exec` is a guest-vsock connect — the exact call that trips the Apple
# Virtualization.framework trap and crashes the VM. The mounts notice is the
# positive signal anchoring the absence checks: tart-up got past the liveness
# gate rather than dying early.
runup running app-a "$EMPTY" "$MNTS" app-a
assert_rc       "running+alive → exit 0" 0
assert_contains "running+alive → mounts attach-at-boot notice" "$(cat "$ERR")" "configured mount(s) attach at boot"
calls="$(cat "$CALLS")"
assert_absent "running → no tart run issued"        "$calls" "tart run"
assert_absent "running → no provisioning vsock hit" "$calls" "hostname -s"

# listed "running" with no live `tart run` process is the wedged-crash
# signature: fail fast with the remedy instead of polling a ghost for minutes.
MOCK_ALIVE=0 runup running app-a "$EMPTY" "$EMPTY" app-a
assert_rc       "wedged (running, no process) → exit 1" 1
assert_contains "wedge diagnostic names the remedy" "$(cat "$ERR")" "tart stop app-a"
assert_absent   "wedged → no tart run issued" "$(cat "$CALLS")" "tart run"

# hostname branch: a mismatch sets it; an already-correct hostname leaves it
runup stopped wrong-name "$EMPTY" "$EMPTY" app-a
assert_contains "hostname mismatch → set-hostname" "$(cat "$CALLS")" "hostnamectl set-hostname app-a"
runup stopped app-a "$EMPTY" "$EMPTY" app-a
assert_absent "hostname already correct → no set-hostname" "$(cat "$CALLS")" "set-hostname"

# prefix lookup: stored bare `app-a`, asked as `tart-app-a`
runup stopped app-a "$EMPTY" "$EMPTY" tart-app-a
assert_contains "prefix lookup tart-app-a → app-a" "$(cat "$CALLS")" "tart run app-a --no-graphics"

printf '\n  %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
