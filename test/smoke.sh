#!/usr/bin/env bash
# Characterization tests for script/smoke — no VM is cloned, booted, sshed, or
# deleted: tart-new/tart-up/tart-rm are mocks in a dir that TART_SMOKE_BIN
# (script/smoke's helper-resolution seam) points at, and ssh is the same dir
# PATH-shimmed; every call records to $CALLS. MOCK_SSH_HOSTNAME fakes the
# guest's answer, MOCK_TART_NEW_RC fakes a create failure (e.g. a name
# collision). Covers arity, the happy-path stage ordering (create → boot →
# BatchMode ssh → teardown), the hostname-mismatch failure with the EXIT-trap
# teardown still firing, SMOKE_KEEP=1 skipping teardown, and a tart-new
# failure propagating with no later stage run (and no teardown — a colliding
# VM is not ours to delete). Plain bash, no framework. Run via script/test or
# directly.
set -uo pipefail

TEST_DIR=$(cd -P "$(dirname "$0")" >/dev/null 2>&1 && pwd)
REPO=$(cd -P "$TEST_DIR/.." >/dev/null 2>&1 && pwd)
SMOKE="$REPO/script/smoke"

pass=0 fail=0
ok()  { pass=$((pass + 1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  FAIL %s\n         %s\n' "$1" "$2"; }
assert_contains() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "want » $3 « in: $2" ;; esac; }
assert_absent()   { case "$2" in *"$3"*) bad "$1" "should NOT contain » $3 «" ;; *) ok "$1" ;; esac; }
check_rc() { local l="$1" want="$2"; shift 2; local got=0; "$@" >/dev/null 2>&1 || got=$?
  if [ "$got" -eq "$want" ]; then ok "$l"; else bad "$l" "want rc=$want got rc=$got"; fi; }
assert_rc() { # label want — checks $rc from the last run_smoke
  if [ "$rc" -eq "$2" ]; then ok "$1"; else bad "$1" "want rc=$2 got rc=$rc"; fi; }
line_of() { grep -n -- "$1" "$CALLS" 2>/dev/null | head -n 1 | cut -d: -f1; }
assert_order() { # label earlier-pattern later-pattern — both in $CALLS, in that order
  local l="$1" a b
  a=$(line_of "$2"); b=$(line_of "$3")
  if [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ]; then ok "$l"
  else bad "$l" "want » $2 « (line ${a:-absent}) before » $3 « (line ${b:-absent}) in: $(tr '\n' '|' < "$CALLS")"; fi
}

WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
MOCKBIN="$WORK/bin"; mkdir -p "$MOCKBIN"
CALLS="$WORK/calls"; export CALLS
ERR="$WORK/stderr"

# Mocks: every call lands in $CALLS. tart-new fails with $MOCK_TART_NEW_RC
# behind a collision-shaped stderr line (the gate smoke relies on); ssh
# answers $MOCK_SSH_HOSTNAME the way the guest's `hostname -s` would.
cat > "$MOCKBIN/tart-new" <<'M'
#!/usr/bin/env bash
echo "tart-new $*" >> "$CALLS"
if [ "${MOCK_TART_NEW_RC:-0}" -ne 0 ]; then
  echo "tart-new: VM 'smoke-vm' already exists. Use a different name, or 'tart delete smoke-vm' first." >&2
  exit "${MOCK_TART_NEW_RC}"
fi
M
cat > "$MOCKBIN/tart-up" <<'M'
#!/usr/bin/env bash
echo "tart-up $*" >> "$CALLS"
exit "${MOCK_TART_UP_RC:-0}"
M
cat > "$MOCKBIN/tart-rm" <<'M'
#!/usr/bin/env bash
echo "tart-rm $*" >> "$CALLS"
M
cat > "$MOCKBIN/ssh" <<'M'
#!/usr/bin/env bash
echo "ssh $*" >> "$CALLS"
[ "${MOCK_SSH_RC:-0}" -eq 0 ] || exit "${MOCK_SSH_RC}"
printf '%s\n' "${MOCK_SSH_HOSTNAME:-smoke-vm}"
M
chmod +x "$MOCKBIN/tart-new" "$MOCKBIN/tart-up" "$MOCKBIN/tart-rm" "$MOCKBIN/ssh"

run_smoke() { # args... — exit code in $rc, stderr in $ERR, recorded calls in $CALLS
  : > "$CALLS"; rc=0
  PATH="$MOCKBIN:$PATH" TART_SMOKE_BIN="$MOCKBIN" \
    MOCK_TART_NEW_RC="${MOCK_TART_NEW_RC-0}" \
    MOCK_TART_UP_RC="${MOCK_TART_UP_RC-0}" \
    MOCK_SSH_RC="${MOCK_SSH_RC-0}" \
    MOCK_SSH_HOSTNAME="${MOCK_SSH_HOSTNAME-smoke-vm}" \
    SMOKE_KEEP="${SMOKE_KEEP-}" \
    bash "$SMOKE" "$@" >"$WORK/out" 2>"$ERR" || rc=$?
}

# argument validation
check_rc "no args → exit 64"  64 bash "$SMOKE"
check_rc "one arg → exit 64"  64 bash "$SMOKE" php
check_rc "--help → exit 0"    0  bash "$SMOKE" --help

# happy path: the four stages in order, ssh non-interactive against the
# prefixed alias, clean exit
run_smoke php fedora
assert_rc       "happy path → exit 0" 0
assert_order    "tart-new precedes tart-up" "tart-new smoke-vm php fedora" "tart-up smoke-vm"
assert_order    "tart-up precedes ssh"      "tart-up smoke-vm" "ssh "
assert_order    "ssh precedes tart-rm"      "ssh " "tart-rm smoke-vm"
assert_contains "ssh runs under BatchMode"      "$(cat "$CALLS")" "BatchMode=yes"
assert_contains "ssh dials the prefixed alias"  "$(cat "$CALLS")" "tart-smoke-vm"
assert_contains "verdict line says OK"          "$(cat "$ERR")" "OK"

# hostname mismatch: fails naming expected vs got — and the EXIT trap still
# tears the VM down
MOCK_SSH_HOSTNAME="wrong-host" run_smoke php fedora
assert_rc       "hostname mismatch → exit 1" 1
assert_contains "mismatch names the expected hostname" "$(cat "$ERR")" "expected 'smoke-vm'"
assert_contains "mismatch names the got hostname"      "$(cat "$ERR")" "got 'wrong-host'"
assert_contains "mismatch → teardown still ran (trap)" "$(cat "$CALLS")" "tart-rm smoke-vm"

# SMOKE_KEEP=1: the run passes but the VM is left up for debugging
SMOKE_KEEP=1 run_smoke php fedora
assert_rc       "SMOKE_KEEP=1 → exit 0" 0
assert_absent   "SMOKE_KEEP=1 → no tart-rm"     "$(cat "$CALLS")" "tart-rm"
assert_contains "SMOKE_KEEP=1 → says it kept the VM" "$(cat "$ERR")" "keeping"

# mid-chain failures: the trap property must hold for EVERY post-create stage
# — teardown fires, the stage's exit code survives it.
MOCK_TART_UP_RC=5 run_smoke php fedora
assert_rc       "tart-up failure propagates its exit code" 5
assert_absent   "tart-up failure → no ssh attempted" "$(cat "$CALLS")" "ssh "
assert_contains "tart-up failure → teardown still ran (trap)" "$(cat "$CALLS")" "tart-rm smoke-vm"

MOCK_SSH_RC=255 run_smoke php fedora
assert_rc       "ssh failure propagates its exit code" 255
assert_contains "ssh failure → FAIL framing with the key-mode hint" "$(cat "$ERR")" "Touch ID"
assert_contains "ssh failure → teardown still ran (trap)" "$(cat "$CALLS")" "tart-rm smoke-vm"

# tart-new failure (e.g. name collision): its exit code propagates, no later
# stage runs, and no teardown — the colliding VM is not ours to delete
MOCK_TART_NEW_RC=7 run_smoke php fedora
assert_rc       "tart-new failure propagates its exit code" 7
assert_absent   "tart-new failure → no ssh attempted" "$(cat "$CALLS")" "ssh "
assert_absent   "tart-new failure → no tart-up"       "$(cat "$CALLS")" "tart-up"
assert_absent   "tart-new failure → no teardown of a VM we don't own" "$(cat "$CALLS")" "tart-rm"
assert_contains "tart-new's own error surfaces" "$(cat "$ERR")" "already exists"

printf '\n  %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
