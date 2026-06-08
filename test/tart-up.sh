#!/usr/bin/env bash
# Characterization tests for bin/tart-up's runtime flow — the path findings #2/#6 live
# in, previously uncovered. A mocked `tart` (list/run/ip/exec) + `nc` drive it with no
# real VM: the mocks make the IP poll and the :22 probe succeed on the first iteration,
# so there are no real sleeps. Covers resolve + prefix lookup, base-image refusal, the
# stopped→`tart run` command (incl. netpolicy + mount flags), the running-VM skip, and
# the hostname-set branch. Plain bash, no framework. Run via script/test or directly.
set -uo pipefail

TEST_DIR=$(cd -P "$(dirname "$0")" >/dev/null 2>&1 && pwd)
REPO=$(cd -P "$TEST_DIR/.." >/dev/null 2>&1 && pwd)
BIN="$REPO/bin"

pass=0 fail=0
ok()  { pass=$((pass + 1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  FAIL %s\n         %s\n' "$1" "$2"; }
assert_contains() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "want » $3 « in: $2" ;; esac; }
assert_absent()   { case "$2" in *"$3"*) bad "$1" "should NOT contain » $3 «" ;; *) ok "$1" ;; esac; }
check_rc() { local l="$1" want="$2"; shift 2; local got=0; "$@" >/dev/null 2>&1 || got=$?
  if [ "$got" -eq "$want" ]; then ok "$l"; else bad "$l" "want rc=$want got rc=$got"; fi; }

WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
MOCKBIN="$WORK/bin"; mkdir -p "$MOCKBIN"
CALLS="$WORK/calls"; export CALLS
EMPTY="$WORK/empty"; : > "$EMPTY"

# Mock `tart`: `list` emits one VM (name=$MOCK_VM, state=$MOCK_STATE); `ip` returns
# $MOCK_IP; `exec <vm> hostname -s` returns $MOCK_HOSTNAME (drives the set-hostname
# branch); `run` and any other `exec` just record. Every call is logged to $CALLS.
cat > "$MOCKBIN/tart" <<'TART'
#!/usr/bin/env bash
echo "tart $*" >> "$CALLS"
case "$1" in
  list) printf '[{"Name":"%s","State":"%s"}]\n' "${MOCK_VM:-app-a}" "${MOCK_STATE:-stopped}" ;;
  ip)   printf '%s\n' "${MOCK_IP:-10.0.0.9}" ;;
  exec) shift 2; [ "$*" = "hostname -s" ] && printf '%s\n' "${MOCK_HOSTNAME:-app-a}"; exit 0 ;;
  run)  echo "MOCK_TART_RUN_STDERR_MARKER" >&2; exit 0 ;;  # stderr → tart-up's per-VM log
  *)    exit 0 ;;
esac
TART
chmod +x "$MOCKBIN/tart"
printf '#!/usr/bin/env bash\nexit 0\n' > "$MOCKBIN/nc"; chmod +x "$MOCKBIN/nc"  # :22 probe always ready

# Run tart-up with the mocks prepended (real jq/seq/sleep/etc. stay on PATH).
runup() { # <state> <hostname> <netpolicy-file> <mounts-file> <vm-arg>
  : > "$CALLS"
  PATH="$MOCKBIN:$PATH" MOCK_VM=app-a MOCK_STATE="$1" MOCK_IP=10.0.0.9 MOCK_HOSTNAME="$2" \
    TART_NETPOLICY="$3" TART_MOUNTS="$4" TART_LOG_DIR="$WORK/logs" \
    bash "$BIN/tart-up" "$5" >/dev/null 2>&1
  # The stopped-VM `tart run` is backgrounded (& disown); give the mock up to ~2s to log it.
  local _; for _ in $(seq 1 20); do grep -q 'tart run' "$CALLS" 2>/dev/null && break; sleep 0.1; done
}

# argument count
check_rc "no args → exit 64"  64 env PATH="$MOCKBIN:$PATH" bash "$BIN/tart-up"
check_rc "two args → exit 64" 64 env PATH="$MOCKBIN:$PATH" bash "$BIN/tart-up" a b

# unknown VM (mock lists a different name) → exit 1
check_rc "unknown VM → exit 1" 1 \
  env PATH="$MOCKBIN:$PATH" MOCK_VM=other MOCK_STATE=stopped TART_NETPOLICY="$EMPTY" TART_MOUNTS="$EMPTY" \
  bash "$BIN/tart-up" app-a

# base image refusal (a stack clone-source is not a dev VM)
check_rc "base image (fedora-php) → exit 1" 1 \
  env PATH="$MOCKBIN:$PATH" MOCK_VM=fedora-php MOCK_STATE=stopped TART_NETPOLICY="$EMPTY" TART_MOUNTS="$EMPTY" \
  bash "$BIN/tart-up" fedora-php

# stopped → `tart run` carries the netpolicy + mount flags
NETP="$WORK/netpolicy"; printf -- '--net-softnet=@host-only\n' > "$NETP"
MNTS="$WORK/mounts";    printf -- '* /srv/data:ro\n'           > "$MNTS"
runup stopped app-a "$NETP" "$MNTS" app-a
calls="$(cat "$CALLS")"
assert_contains "stopped → tart run --no-graphics"      "$calls" "tart run app-a --no-graphics"
assert_contains "stopped → run carries netpolicy flag"  "$calls" "--net-softnet=@host-only"
assert_contains "stopped → run carries dir-mount flag"  "$calls" "--dir=data:/srv/data:ro"
assert_contains "stopped → provisions over vsock (hostname probe)" "$calls" "hostname -s"

# tart's own stderr is captured to a per-VM log (truncate-on-start) so a crash's
# `fixme:` line survives; the mock `tart run` emits a stderr marker.
runlog="$WORK/logs/app-a.run.log"
for _ in $(seq 1 20); do [ -s "$runlog" ] && break; sleep 0.1; done
assert_contains "stopped → tart run stderr captured to per-VM log" "$(cat "$runlog" 2>/dev/null)" "MOCK_TART_RUN_STDERR_MARKER"

# running → no `tart run` issued, AND no guest-agent provisioning: an already-up
# VM was provisioned on the boot that started it, so re-probing its hostname /
# host-keys every login is pure waste — and each `tart exec` is a guest-vsock
# connect, the exact call that trips the Apple Virtualization.framework trap and
# crashes the VM. Skipping it for already-running VMs removes the recurring hit.
runup running app-a "$EMPTY" "$EMPTY" app-a
assert_absent "running → no tart run issued" "$(cat "$CALLS")" "tart run"
assert_absent "running → no provisioning vsock hit" "$(cat "$CALLS")" "hostname -s"

# hostname branch (#6): mismatch sets it; an already-correct hostname leaves it
runup stopped wrong-name "$EMPTY" "$EMPTY" app-a
assert_contains "hostname mismatch → set-hostname" "$(cat "$CALLS")" "hostnamectl set-hostname app-a"
runup stopped app-a "$EMPTY" "$EMPTY" app-a
assert_absent "hostname already correct → no set-hostname" "$(cat "$CALLS")" "set-hostname"

# prefix lookup: stored bare `app-a`, asked as `tart-app-a`
runup stopped app-a "$EMPTY" "$EMPTY" tart-app-a
assert_contains "prefix lookup tart-app-a → app-a" "$(cat "$CALLS")" "tart run app-a --no-graphics"

printf '\n  %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
