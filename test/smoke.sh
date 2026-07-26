#!/usr/bin/env bash
# Characterization tests for script/smoke — no VM is cloned, booted, sshed, or
# deleted: tart-new/tart-up/tart-rm are mocks in a dir that TART_SMOKE_BIN
# (script/smoke's helper-resolution seam) points at, and ssh is the same dir
# PATH-shimmed; every call records to $CALLS. MOCK_SSH_HOSTNAME fakes the
# guest's answer, MOCK_TART_NEW_RC fakes a create failure (e.g. a name
# collision). Covers arity, the happy-path stage ordering (create → boot →
# guest-agent probe → BatchMode ssh → teardown), the hostname-mismatch failure with the EXIT-trap
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
bad() { fail=$((fail + 1)); printf '  FAIL %s\n         %s\n' "$1" "${2:-}"; }
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
case "$*" in
  *tart-stacks-vnc.service*)
    exit "${MOCK_VNC_START_RC:-0}" ;;
  */dev/tcp/127.0.0.1/5901*)
    [ "${MOCK_VNC_BANNER_RC:-0}" -eq 0 ] || exit "${MOCK_VNC_BANNER_RC}"
    printf '%s' "${MOCK_VNC_BANNER:-RFB}" ;;
  *tart-stacks-release*)
    # The provenance the attestation reads. Each field is a knob so a mislabeled
    # image can be staged — which is the whole point of the check.
    printf 'built: 2026-01-01T00:00:00Z\n'
    printf 'stack: %s\n'  "${MOCK_MANIFEST_STACK:-php}"
    printf 'distro: %s\n' "${MOCK_MANIFEST_DISTRO:-fedora}"
    printf 'gui: %s\n'    "${MOCK_MANIFEST_GUI:-none}"
    printf 'os-id: %s\n'  "${MOCK_MANIFEST_OSID:-fedora}" ;;
  *"sshd -T"*)
    [ "${MOCK_SSHD_T_RC:-0}" -eq 0 ] || exit "$MOCK_SSHD_T_RC"
    printf '%s\n' "${MOCK_SSHD_T-passwordauthentication no
permitrootlogin no
kbdinteractiveauthentication no
pubkeyauthentication yes
streamlocalbindunlink yes}" ;;
  *--version*|*-version*)
    exit "${MOCK_TOOL_RC:-0}" ;;
  *"ss -tln"*)
    # Default is the loopback bind the image contract promises; the knob stages
    # the bind the RFB banner cannot distinguish from it. MOCK_VNC_SS_RC fails
    # the read itself, which must not read as "nothing is listening".
    [ "${MOCK_VNC_SS_RC:-0}" -eq 0 ] || exit "$MOCK_VNC_SS_RC"
    printf '%s\n' "${MOCK_VNC_LISTENERS-LISTEN 0 5 127.0.0.1:5901 0.0.0.0:*}" ;;
  *)
    printf '%s\n' "${MOCK_SSH_HOSTNAME:-smoke-vm}" ;;
esac
M
# `tart` itself, for the guest-agent stage: `tart exec` is a vsock call, so it
# fails in ways ssh cannot — the agent absent (control-socket error) and the
# agent answering but unable to escalate are separate knobs because they break
# different cells.
cat > "$MOCKBIN/tart" <<'M'
#!/usr/bin/env bash
echo "tart $*" >> "$CALLS"
case "$*" in
  *"sudo -n true"*)
    if [ "${MOCK_TART_SUDO_RC:-0}" -ne 0 ]; then
      echo "sudo: a password is required" >&2
      exit "${MOCK_TART_SUDO_RC}"
    fi ;;
  *"hostname -s"*)
    if [ "${MOCK_TART_EXEC_RC:-0}" -ne 0 ]; then
      echo "Failed to connect to the VM using its control socket, is the Tart Guest Agent running?" >&2
      exit "${MOCK_TART_EXEC_RC}"
    fi
    printf '%s\n' "${MOCK_TART_EXEC_HOSTNAME:-smoke-vm}" ;;
esac
M
chmod +x "$MOCKBIN/tart-new" "$MOCKBIN/tart-up" "$MOCKBIN/tart-rm" "$MOCKBIN/ssh" "$MOCKBIN/tart"

run_smoke() { # args... — exit code in $rc, stderr in $ERR, recorded calls in $CALLS
  : > "$CALLS"; rc=0
  PATH="$MOCKBIN:$PATH" TART_SMOKE_BIN="$MOCKBIN" \
    MOCK_TART_NEW_RC="${MOCK_TART_NEW_RC-0}" \
    MOCK_TART_UP_RC="${MOCK_TART_UP_RC-0}" \
    MOCK_SSH_RC="${MOCK_SSH_RC-0}" \
    MOCK_SSH_HOSTNAME="${MOCK_SSH_HOSTNAME-smoke-vm}" \
    MOCK_VNC_START_RC="${MOCK_VNC_START_RC-0}" \
    MOCK_VNC_BANNER="${MOCK_VNC_BANNER-RFB}" \
    MOCK_VNC_BANNER_RC="${MOCK_VNC_BANNER_RC-0}" \
    MOCK_VNC_LISTENERS="${MOCK_VNC_LISTENERS-LISTEN 0 5 127.0.0.1:5901 0.0.0.0:*}" \
    MOCK_VNC_SS_RC="${MOCK_VNC_SS_RC-0}" \
    MOCK_MANIFEST_STACK="${MOCK_MANIFEST_STACK-php}" \
    MOCK_MANIFEST_DISTRO="${MOCK_MANIFEST_DISTRO-fedora}" \
    MOCK_MANIFEST_GUI="${MOCK_MANIFEST_GUI-none}" \
    MOCK_MANIFEST_OSID="${MOCK_MANIFEST_OSID-fedora}" \
    MOCK_SSHD_T="${MOCK_SSHD_T-passwordauthentication no
permitrootlogin no
kbdinteractiveauthentication no
pubkeyauthentication yes
streamlocalbindunlink yes}" \
    MOCK_SSHD_T_RC="${MOCK_SSHD_T_RC-0}" \
    MOCK_TART_EXEC_RC="${MOCK_TART_EXEC_RC-0}" \
    MOCK_TART_SUDO_RC="${MOCK_TART_SUDO_RC-0}" \
    MOCK_TOOL_RC="${MOCK_TOOL_RC-0}" \
    SMOKE_VNC_TRIES=2 SMOKE_VNC_DELAY=0 \
    SMOKE_KEEP="${SMOKE_KEEP-}" \
    bash "$SMOKE" "$@" >"$WORK/out" 2>"$ERR" || rc=$?
}

# argument validation
check_rc "no args → exit 64"   64 bash "$SMOKE"
check_rc "one arg → exit 64"   64 bash "$SMOKE" php
check_rc "four args → exit 64" 64 bash "$SMOKE" php fedora kde extra
check_rc "--help → exit 0"     0  bash "$SMOKE" --help

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

# The guest-agent stage. `tart exec` rides tart-guest-agent's vsock channel, not
# ssh, and nothing in this repo installs that agent — so every other stage here
# passes on an image that has none, while tart-up's hostname set silently
# degrades and GUI activation hard-fails. It runs before the hostname assert on
# purpose: a wrong hostname is this failure's symptom, and reporting the symptom
# points the reader at provisioning instead of at the missing agent.
echo "  -- guest agent (vsock) --"
assert_order    "tart-up precedes the guest-agent probe" "tart-up smoke-vm" "tart exec smoke-vm hostname"
assert_order    "guest-agent probe precedes ssh"         "tart exec smoke-vm hostname" "ssh "
assert_contains "escalation is probed too"      "$(cat "$CALLS")" "tart exec smoke-vm sudo -n true"
assert_contains "verdict names the guest agent" "$(cat "$ERR")" "guest agent"

# The guest answers `fedora` here because that is what an agent-less VM really
# reports: tart-up sets the hostname over this very channel, so when the agent
# is gone the guest keeps the base image's own name. Staging both halves is what
# makes the ordering assertion below mean anything — with the probe moved after
# the ssh block, smoke blames the hostname for the agent's absence.
MOCK_TART_EXEC_RC=1 MOCK_SSH_HOSTNAME=fedora run_smoke php fedora
assert_rc       "absent guest agent → FAIL" 1
assert_contains "absent agent names the channel"     "$(cat "$ERR")" "'tart exec' does not answer"
assert_contains "absent agent says it is not ssh"    "$(cat "$ERR")" "not ssh"
assert_contains "absent agent surfaces tart's reason" "$(cat "$ERR")" "is the Tart Guest Agent running?"
assert_absent   "absent agent → hostname mismatch never blamed" "$(cat "$ERR")" "guest hostname: expected"
assert_absent   "absent agent → no ssh attempted"      "$(cat "$CALLS")" "ssh "
assert_contains "absent agent → teardown still ran"    "$(cat "$CALLS")" "tart-rm smoke-vm"

# An agent that answers but cannot escalate breaks only the GUI cells, so the
# unprivileged probe above still reports ok — this is a distinct verdict.
MOCK_TART_SUDO_RC=1 run_smoke php fedora
assert_rc       "guest agent without sudo → FAIL" 1
assert_contains "no-sudo names escalation"       "$(cat "$ERR")" "cannot escalate"
assert_contains "no-sudo surfaces sudo's reason" "$(cat "$ERR")" "a password is required"
assert_contains "no-sudo → teardown still ran"   "$(cat "$CALLS")" "tart-rm smoke-vm"

# GUI flavor: the optional <de> rides through to tart-new (flavor image
# selection is tart-new's job), the VNC surface is exercised (unit start +
# loopback RFB banner), and the verdict says so
MOCK_MANIFEST_GUI=kde run_smoke php fedora kde
assert_rc       "GUI flavor → exit 0" 0
assert_contains "de reaches tart-new"        "$(cat "$CALLS")" "tart-new smoke-vm php fedora kde"
assert_contains "GUI smoke starts the VNC unit" "$(cat "$CALLS")" "tart-stacks-vnc.service"
assert_contains "GUI smoke probes loopback 5901" "$(cat "$CALLS")" "/dev/tcp/127.0.0.1/5901"
assert_contains "verdict names the flavor"   "$(cat "$ERR")" "fedora-php-kde"
assert_contains "verdict includes the vnc stage" "$(cat "$ERR")" "sshd posture, vnc"
assert_contains "verdict names the attestation stages" "$(cat "$ERR")" "manifest, os-release, toolchain"

# non-GUI run never touches the VNC surface
run_smoke php fedora
assert_absent   "plain smoke does not start the VNC unit" "$(cat "$CALLS")" "tart-stacks-vnc"

# VNC unit fails to start → smoke fails, teardown still fires
MOCK_MANIFEST_GUI=kde MOCK_VNC_START_RC=9 run_smoke php fedora kde
assert_rc       "vnc start failure → exit 9" 9
assert_contains "vnc start failure names the unit" "$(cat "$ERR")" "tart-stacks-vnc.service failed to start"
assert_contains "vnc start failure still tears down" "$(cat "$CALLS")" "tart-rm smoke-vm"

# wrong banner on 5901 → smoke fails naming the port
MOCK_MANIFEST_GUI=kde MOCK_VNC_BANNER=XXX run_smoke php fedora kde
assert_rc       "bad RFB banner → exit 1" 1
assert_contains "bad banner names the loopback port" "$(cat "$ERR")" "127.0.0.1:5901"

# listener never answers (probe rc!=0 through all retries) → smoke fails
MOCK_MANIFEST_GUI=kde MOCK_VNC_BANNER_RC=1 run_smoke php fedora kde
assert_rc       "dead listener → exit 1" 1
assert_contains "dead listener reports nothing received" "$(cat "$ERR")" "got 'nothing'"

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


# The RFB probe dials 127.0.0.1, so it answers identically whether Xvnc bound
# loopback or 0.0.0.0 — it passes in exactly the failure case. The unit ships
# SecurityTypes=None, so the bind address IS the authentication.
MOCK_MANIFEST_GUI=kde run_smoke php fedora kde
assert_rc       "loopback bind → smoke passes" 0
assert_contains "loopback bind → listener table read" "$(cat "$CALLS")" "ss -tln"

MOCK_MANIFEST_GUI=kde MOCK_VNC_LISTENERS='LISTEN 0 5 0.0.0.0:5901 0.0.0.0:*' run_smoke php fedora kde
assert_rc       "non-loopback vnc bind → smoke FAILS" 1
assert_contains "non-loopback bind → names the exposure" "$(cat "$ERR")" "bound beyond loopback"
assert_contains "non-loopback bind → explains why it matters" "$(cat "$ERR")" "no VNC password"

MOCK_MANIFEST_GUI=kde MOCK_VNC_LISTENERS='LISTEN 0 5 [::]:5901 [::]:*' run_smoke php fedora kde
assert_rc       "ipv6 wildcard vnc bind → smoke FAILS" 1

# The gate is an allowlist, so a bind to one specific non-loopback address — the
# VM's own, which no enumeration of wildcard spellings covers — fails too.
MOCK_MANIFEST_GUI=kde MOCK_VNC_LISTENERS='LISTEN 0 5 192.168.64.7:5901 0.0.0.0:*' run_smoke php fedora kde
assert_rc       "specific non-loopback vnc bind → smoke FAILS" 1
assert_contains "specific bind → names the address" "$(cat "$ERR")" "192.168.64.7:5901"

MOCK_MANIFEST_GUI=kde MOCK_VNC_LISTENERS='LISTEN 0 5 [fd00::5]:5901 [::]:*' run_smoke php fedora kde
assert_rc       "specific non-loopback v6 vnc bind → smoke FAILS" 1

MOCK_MANIFEST_GUI=kde MOCK_VNC_LISTENERS='LISTEN 0 5 *:5901 *:*' run_smoke php fedora kde
assert_rc       "bare-star vnc bind → smoke FAILS" 1

# Both loopback families together is the normal shape once Xvnc has bound v4 and
# v6 — a classifier that accepted only one form would fail a healthy image.
MOCK_MANIFEST_GUI=kde MOCK_VNC_LISTENERS='LISTEN 0 5 127.0.0.1:5901 0.0.0.0:*
LISTEN 0 5 [::1]:5901 [::]:*' run_smoke php fedora kde
assert_rc       "v4+v6 loopback binds → smoke passes" 0

# An unsafe listener alongside a loopback one must still fail: the check is
# per-line, not "does any loopback listener exist".
MOCK_MANIFEST_GUI=kde MOCK_VNC_LISTENERS='LISTEN 0 5 127.0.0.1:5901 0.0.0.0:*
LISTEN 0 5 0.0.0.0:5901 0.0.0.0:*' run_smoke php fedora kde
assert_rc       "loopback plus wildcard bind → smoke FAILS" 1

# "The table read failed" and "the table has no :5901 row" are different
# verdicts: one is an unverified image, the other a defective one.
MOCK_MANIFEST_GUI=kde MOCK_VNC_SS_RC=1 run_smoke php fedora kde
assert_rc       "listener-table read failure → smoke FAILS" 1
assert_contains "listener-table read failure → says the bind is unverified" "$(cat "$ERR")" "unverified"

MOCK_MANIFEST_GUI=kde MOCK_VNC_LISTENERS='' run_smoke php fedora kde
assert_rc       "no :5901 listener → smoke FAILS" 1
assert_contains "no :5901 listener → says nothing is listening" "$(cat "$ERR")" "nothing listening on :5901"

# Attestation: booting and answering does not prove the image IS the cell asked
# for. tart-new checks only the image NAME and tart-up supplies the hostname, so
# without these a mislabeled or stale image passes every earlier stage.
echo "  -- image attestation --"
MOCK_MANIFEST_STACK=jvm run_smoke php fedora
assert_rc       "manifest stack mismatch → FAIL" 1
assert_contains "stack mismatch names both values" "$(cat "$ERR")" "expected 'php', guest reports 'jvm'"
assert_contains "stack mismatch → teardown still ran" "$(cat "$CALLS")" "tart-rm smoke-vm"

MOCK_MANIFEST_DISTRO=ubuntu run_smoke php fedora
assert_rc       "manifest distro mismatch → FAIL" 1
assert_contains "distro mismatch names both values" "$(cat "$ERR")" "expected 'fedora', guest reports 'ubuntu'"

# The manifest is written from the build's own DISTRO, so it can agree with the
# request and still be wrong about the guest. os-release is the guest's own answer.
MOCK_MANIFEST_OSID=ubuntu run_smoke php fedora
assert_rc       "guest os-release disagrees with the manifest → FAIL" 1
assert_contains "os-release mismatch is reported separately" "$(cat "$ERR")" "guest os-release id"

MOCK_MANIFEST_GUI=kde run_smoke php fedora
assert_rc       "a GUI image smoked as headless → FAIL" 1
MOCK_MANIFEST_GUI=none run_smoke php fedora kde
assert_rc       "a headless image smoked as a GUI flavor → FAIL" 1

# The toolchain has to answer over a non-interactive ssh — the shape an agent or
# a script uses, and the one that was broken until the shims landed on PATH.
MOCK_TOOL_RC=127 run_smoke php fedora
assert_rc       "toolchain unreachable non-interactively → FAIL" 1
assert_contains "toolchain failure explains the consequence" "$(cat "$ERR")" "PATH wiring is broken"
run_smoke php fedora
assert_contains "php stack probes php"  "$(cat "$CALLS")" "php --version"
MOCK_MANIFEST_STACK=jvm run_smoke jvm fedora
assert_contains "jvm stack probes java" "$(cat "$CALLS")" "java -version"

# The hardening posture, read from sshd's effective config rather than the file.
for missing in "passwordauthentication no" "permitrootlogin no" "kbdinteractiveauthentication no" "streamlocalbindunlink yes"; do
  MOCK_SSHD_T="$(printf 'passwordauthentication no\npermitrootlogin no\nkbdinteractiveauthentication no\nstreamlocalbindunlink yes\n' | grep -vx "$missing")" \
    run_smoke php fedora
  assert_rc       "sshd missing '$missing' → FAIL" 1
  assert_contains "sshd failure names the setting" "$(cat "$ERR")" "$missing"
done
MOCK_SSHD_T_RC=1 run_smoke php fedora
assert_rc       "sshd -T unreadable → FAIL" 1
assert_contains "unreadable sshd config says the posture is unverified" "$(cat "$ERR")" "hardening posture is unverified"

printf '\n  %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
