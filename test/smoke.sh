#!/usr/bin/env bash
# Characterization tests for script/smoke — no VM is cloned, booted, sshed, or
# deleted: tart-new/tart-up/tart-rm are mocks in a dir that TART_SMOKE_BIN
# (script/smoke's helper-resolution seam) points at, and ssh and tart are the
# same dir PATH-shimmed; every call records to $CALLS. MOCK_SSH_HOSTNAME fakes
# the guest's answer, MOCK_TART_NEW_RC fakes a create failure (e.g. a name
# collision). Covers arity, the happy-path stage ordering (create → boot →
# guest-agent probes → BatchMode ssh → teardown), the hostname-mismatch failure
# with the EXIT-trap teardown still firing, the four guest-agent verdicts (dead
# channel, no escalation, a failing guest `hostname`, a name that never landed)
# and their ordering,
# SMOKE_KEEP=1 skipping teardown, and a tart-new failure propagating with no
# later stage run (and no teardown — a colliding VM is not ours to delete).
# Plain bash, no framework. Run via script/test or directly.
set -uo pipefail

TEST_DIR=$(cd -P "$(dirname "$0")" >/dev/null 2>&1 && pwd)
REPO=$(cd -P "$TEST_DIR/.." >/dev/null 2>&1 && pwd)
SMOKE="$REPO/script/smoke"

pass=0 fail=0
ok()  { pass=$((pass + 1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  FAIL %s\n         %s\n' "$1" "${2:-}"; }
assert_contains() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "want » $3 « in: $2" ;; esac; }
assert_absent()   { case "$2" in *"$3"*) bad "$1" "should NOT contain » $3 «" ;; *) ok "$1" ;; esac; }
assert_probe_line() { # label probe — the EXACT ssh-argv line a probe must produce,
  # whole-line matched: a substring match would tolerate extra ssh arguments
  # around the expected remote command.
  if grep -qxF "ssh-argv [-n] [-o] [BatchMode=yes] [tart-smoke-vm] [$2]" "$CALLS"; then
    ok "$1"
  else
    bad "$1" "no exact ssh-argv line for » $2 « in: $(grep '^ssh-argv' "$CALLS" | tr '\n' '|')"
  fi
}
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
# A second record with each argv element bracketed: the flattened line above
# cannot distinguish one remote command from several arguments, so the probe
# assertions match this exact-capture form — a raw declaration row leaking to
# ssh as the command is visible here and invisible above.
{ printf 'ssh-argv'; printf ' [%s]' "$@"; echo; } >> "$CALLS"
[ "${MOCK_SSH_RC:-0}" -eq 0 ] || exit "${MOCK_SSH_RC}"
case "$*" in
  "command -v "*|*" command -v "*)
    exit "${MOCK_TOOL_RC:-0}" ;;
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
    printf 'os: %s\n' "${MOCK_MANIFEST_OS:-fedora}"
    # Stages the failure mode the regression guard exists for: a second
    # top-level `os:` line, which field()'s first-match-then-exit semantics
    # would otherwise read past silently.
    [ "${MOCK_MANIFEST_OS_DUP:-0}" = "1" ] && printf 'os: %s\n' "Fedora Linux 44 (Cloud Edition) (44)"
    printf 'gui: %s\n'    "${MOCK_MANIFEST_GUI:-none}"
    printf 'os-id: %s\n'  "${MOCK_MANIFEST_OSID:-fedora}"
    printf 'sw-vers-id: %s\n' "${MOCK_MANIFEST_SWVERSID:-macos}" ;;
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
  *"netstat -an -p tcp"*)
    # darwin's listener-surface read (99-finalize.sh's own idiom). Default is
    # the healthy image's own posture (:22 alone); the knobs stage the two
    # failure shapes: an extra bound port, and the read itself failing (which
    # must not be reported the same as "the table has no extra port").
    [ "${MOCK_NETSTAT_RC:-0}" -eq 0 ] || exit "$MOCK_NETSTAT_RC"
    printf '%s\n' "${MOCK_NETSTAT_LISTENERS-tcp4 0 0 *.22 *.* LISTEN}" ;;
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
  *"exec smoke-vm true"*)
    if [ "${MOCK_TART_EXEC_RC:-0}" -ne 0 ]; then
      echo "Failed to connect to the VM using its control socket, is the Tart Guest Agent running?" >&2
      exit "${MOCK_TART_EXEC_RC}"
    fi ;;
  *"hostname -s"*)
    if [ "${MOCK_TART_HOSTNAME_RC:-0}" -ne 0 ]; then
      # What tart prints when the GUEST command fails rather than the channel —
      # tart exec propagates the command's own status, so the two are separate
      # states that must not share a verdict.
      echo 'Error: unknown (2): exec: "hostname": executable file not found in $PATH' >&2
      exit "${MOCK_TART_HOSTNAME_RC}"
    fi
    # `-` not `:-`: an empty answer is a state the probe must reject, so it has
    # to survive being set deliberately.
    printf '%s\n' "${MOCK_TART_EXEC_HOSTNAME-smoke-vm}" ;;
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
    MOCK_MANIFEST_OS="${MOCK_MANIFEST_OS-fedora}" \
    MOCK_MANIFEST_OS_DUP="${MOCK_MANIFEST_OS_DUP-0}" \
    MOCK_MANIFEST_GUI="${MOCK_MANIFEST_GUI-none}" \
    MOCK_MANIFEST_OSID="${MOCK_MANIFEST_OSID-fedora}" \
    MOCK_MANIFEST_SWVERSID="${MOCK_MANIFEST_SWVERSID-macos}" \
    MOCK_NETSTAT_LISTENERS="${MOCK_NETSTAT_LISTENERS-tcp4 0 0 *.22 *.* LISTEN}" \
    MOCK_NETSTAT_RC="${MOCK_NETSTAT_RC-0}" \
    MOCK_SSHD_T="${MOCK_SSHD_T-passwordauthentication no
permitrootlogin no
kbdinteractiveauthentication no
pubkeyauthentication yes
streamlocalbindunlink yes}" \
    MOCK_SSHD_T_RC="${MOCK_SSHD_T_RC-0}" \
    MOCK_TART_EXEC_RC="${MOCK_TART_EXEC_RC-0}" \
    MOCK_TART_SUDO_RC="${MOCK_TART_SUDO_RC-0}" \
    MOCK_TART_EXEC_HOSTNAME="${MOCK_TART_EXEC_HOSTNAME-smoke-vm}" \
    MOCK_TART_HOSTNAME_RC="${MOCK_TART_HOSTNAME_RC-0}" \
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
# passes on an image that has none. The three probes are ordered by dependency
# (channel, then escalation over it, then whether tart-up's hostname landed) so
# each failure has one remaining explanation, and all three run before the ssh
# hostname assert, whose bare mismatch is the symptom every one of them causes.
echo "  -- guest agent (vsock) --"
assert_order    "tart-up precedes the guest-agent probe" "tart-up smoke-vm" "tart exec smoke-vm true"
assert_order    "guest-agent probes precede ssh"         "tart exec smoke-vm true" "ssh "
assert_order    "channel is probed before escalation"    "tart exec smoke-vm true" "tart exec smoke-vm sudo -n true"
assert_order    "escalation is probed before the hostname" "tart exec smoke-vm sudo -n true" "tart exec smoke-vm hostname -s"
assert_contains "verdict names the guest agent" "$(cat "$ERR")" "guest agent"
# The channel probe must be a command that cannot itself fail: tart exec returns
# the guest command's own status, so probing with a real one would report that
# command's failure as a dead vsock channel.
assert_contains "channel is probed with 'true'" "$(cat "$CALLS")" "tart exec smoke-vm true"

# A guest staged the way an agent-less one really answers: the hostname stays at
# the base image's own name, because tart-up sets it over the very channel that
# is gone. Both halves matter — with the probes moved after the ssh block, smoke
# blames the hostname for the agent's absence, which is what these pin against.
MOCK_TART_EXEC_RC=1 MOCK_SSH_HOSTNAME=fedora run_smoke php fedora
assert_rc       "absent guest agent → FAIL" 1
assert_contains "absent agent names the channel"     "$(cat "$ERR")" "'tart exec' does not answer"
assert_contains "absent agent says it is not ssh"    "$(cat "$ERR")" "not ssh"
assert_contains "absent agent surfaces tart's reason" "$(cat "$ERR")" "is the Tart Guest Agent running?"
assert_contains "absent agent offers the ssh route"  "$(cat "$ERR")" "ssh tart-smoke-vm systemctl status"
assert_absent   "absent agent → hostname mismatch never blamed" "$(cat "$ERR")" "guest hostname: expected"
assert_absent   "absent agent → no ssh attempted"      "$(cat "$CALLS")" "ssh "
assert_absent   "absent agent → escalation not probed after it" "$(cat "$CALLS")" "sudo -n true"
assert_contains "absent agent → teardown still ran"    "$(cat "$CALLS")" "tart-rm smoke-vm"

# A guest command that fails while the channel is healthy. tart exec propagates
# the command's status, so this is indistinguishable from a dead channel by exit
# code alone — the whole reason the channel is probed with `true` first.
MOCK_TART_HOSTNAME_RC=1 run_smoke php fedora
assert_rc       "guest hostname command fails → FAIL" 1
assert_contains "names the guest command, not the channel" "$(cat "$ERR")" "'hostname -s' failed inside"
assert_contains "says the channel is fine"          "$(cat "$ERR")" "answers and can escalate"
assert_absent   "not blamed on the vsock channel"   "$(cat "$ERR")" "does not answer"
assert_absent   "not blamed on the base image"      "$(cat "$ERR")" "fix is in the base image"

# An agent that answers unprivileged calls but cannot escalate. tart-up needs
# sudo for `hostnamectl` on EVERY cell, not just GUI ones, so the guest is staged
# with the hostname unset here too — which is what makes the ordering meaningful:
# were escalation probed after the hostname comparison, this would be reported as
# a timing race instead of the sudoers failure it is.
MOCK_TART_SUDO_RC=1 MOCK_TART_EXEC_HOSTNAME=fedora run_smoke php fedora
assert_rc       "guest agent without sudo → FAIL" 1
assert_contains "no-sudo names escalation"       "$(cat "$ERR")" "cannot escalate"
assert_contains "no-sudo surfaces sudo's reason" "$(cat "$ERR")" "a password is required"
assert_contains "no-sudo names the every-cell scope" "$(cat "$ERR")" "hostname on every cell"
assert_contains "no-sudo points at the sudoers"  "$(cat "$ERR")" "sudoers drop-in"
assert_absent   "no-sudo → not reported as a hostname problem" "$(cat "$ERR")" "calls itself"
assert_absent   "no-sudo → no ssh attempted"     "$(cat "$CALLS")" "ssh "
assert_contains "no-sudo → teardown still ran"   "$(cat "$CALLS")" "tart-rm smoke-vm"

# Channel and escalation both healthy, but the name never landed. tart-up
# suppresses every failure of that step, so the verdict must offer both causes it
# hides — a probe that beat the agent, and a guest where hostnamectl or
# systemd-hostnamed failed — rather than asserting one of them.
MOCK_TART_EXEC_HOSTNAME=fedora run_smoke php fedora
assert_rc       "agent healthy but hostname stale → FAIL" 1
assert_contains "stale hostname names both values" "$(cat "$ERR")" "calls itself 'fedora' rather than 'smoke-vm'"
assert_contains "stale hostname offers the timing cause" "$(cat "$ERR")" "probed before the agent was listening"
assert_contains "stale hostname offers the guest cause"  "$(cat "$ERR")" "hostnamectl/systemd-hostnamed failed"
assert_absent   "stale hostname → not blamed on the channel" "$(cat "$ERR")" "does not answer"
assert_absent   "stale hostname → no ssh attempted" "$(cat "$CALLS")" "ssh "

# An empty-but-successful reply lands in the same branch: a channel that answers
# with nothing has not established the guest's identity either.
MOCK_TART_EXEC_HOSTNAME='' run_smoke php fedora
assert_rc       "empty vsock reply → FAIL" 1
assert_contains "empty reply is named as empty" "$(cat "$ERR")" "calls itself 'empty'"

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

MOCK_MANIFEST_OS=ubuntu run_smoke php fedora
assert_rc       "manifest OS mismatch → FAIL" 1
assert_contains "OS mismatch names both values" "$(cat "$ERR")" "expected 'fedora', guest reports 'ubuntu'"

# The manifest is written from the build's own OS, so it can agree with the
# request and still be wrong about the guest. os-release is the guest's own answer.
MOCK_MANIFEST_OSID=ubuntu run_smoke php fedora
assert_rc       "guest os-release disagrees with the manifest → FAIL" 1
assert_contains "os-release mismatch is reported separately" "$(cat "$ERR")" "guest os-release id"

# Regression guard: field() returns only the FIRST match on a key and exits, so
# a duplicate `os:` line (as a real manifest once shipped) would silently
# orphan the second instead of failing the attest above. This must fail loudly
# on its own, before field() ever gets a chance to look right.
MOCK_MANIFEST_OS_DUP=1 run_smoke php fedora
assert_rc       "duplicate manifest 'os:' key → FAIL" 1
assert_contains "duplicate os: key names the count" "$(cat "$ERR")" "manifest has 2 'os:' line(s)"
assert_contains "duplicate os: key explains why"     "$(cat "$ERR")" "silently orphans the rest"

MOCK_MANIFEST_GUI=kde run_smoke php fedora
assert_rc       "a GUI image smoked as headless → FAIL" 1
MOCK_MANIFEST_GUI=none run_smoke php fedora kde
assert_rc       "a headless image smoked as a GUI flavor → FAIL" 1

# The toolchain has to answer over a non-interactive ssh — the shape an agent or
# a script uses, and the one that was broken until the shims landed on PATH.
MOCK_TOOL_RC=127 run_smoke php fedora
assert_rc       "toolchain unreachable non-interactively → FAIL" 1
assert_contains "toolchain failure explains the consequence" "$(cat "$ERR")" "PATH wiring is broken"
# The probes come from the proof column of stacks/<stack>/tools, so each
# stack is checked against what IT declares — not against a php-or-else-jvm
# fork that probes a third stack for a runtime it does not have. Asserted
# against the real files rather than a fixture: the point is that the shipped
# declarations are the ones that run. The exact-capture ssh-argv form is what
# proves COLUMN FIVE reached ssh as one whole command — a raw `tool|…` row
# leaking through would carry the delimiter, asserted absent below.
run_smoke php fedora
assert_rc       "php declaration-driven run → exit 0 (probe loop actually ran)" 0
assert_probe_line "php stack probes php (exact remote command)"      "php --version"
assert_probe_line "php stack probes composer (exact remote command)" "composer --version"
assert_probe_line "php stack probes the pnpm shim (exact remote command)" "command -v pnpm"
assert_absent   "php stack does not probe java" "$(cat "$CALLS")" "java"
assert_absent   "no raw declaration row reached ssh as a command" "$(cat "$CALLS")" "[tool|"
MOCK_MANIFEST_STACK=jvm run_smoke jvm fedora
# The rc control is load-bearing: the loop below emits one assertion per
# tool row, so a declaration with zero tool rows would shrink it to zero
# assertions and this whole block would silently stop testing anything.
assert_rc       "jvm declaration-driven run → exit 0 (probe loop actually ran)" 0
jvm_calls="$(cat "$CALLS")"
while IFS= read -r want; do
  assert_probe_line "jvm stack probes '$want' (exact remote command)" "$want"
done < <(awk -F'|' '$1 == "tool" { print $5 }' "$REPO/stacks/jvm/tools")
assert_absent "jvm stack does not probe php" "$jvm_calls" "php --version"
assert_absent "no raw declaration row reached ssh as a command (jvm)" "$jvm_calls" "[tool|"

# A stack with no declaration must FAIL rather than silently probe nothing:
# "toolchain passed" having probed zero commands is the failure mode the data
# file exists to prevent. Pinned to this gate's own wording — the zero-rows
# gate below also names the file, so a looser match would stay green with
# this branch deleted.
MOCK_MANIFEST_STACK=ghost run_smoke ghost fedora
assert_rc       "a stack with no tools file → FAIL" 1
assert_contains "missing declaration names the file" "$(cat "$ERR")" "no tool declaration at"

# Present but declaring no tool rows is the same defect in two shapes —
# comment-only, and ext-rows-only (a valid php-like declaration whose tool
# rows were deleted): both must take the zero-rows gate, and the mixed
# tool+ext control beside them proves ext rows don't break the probe loop.
# script/smoke resolves stacks/ from its own location, so the fixture is a
# scratch repo holding a copy of the script, the libs it sources, the os
# token lists, and the fixture stacks.
FAKE_REPO="$WORK/hollow-repo"
mkdir -p "$FAKE_REPO/script" "$FAKE_REPO/bin/lib" "$FAKE_REPO/shared/linux" \
         "$FAKE_REPO/shared/darwin" "$FAKE_REPO/stacks/hollow" \
         "$FAKE_REPO/stacks/extonly" "$FAKE_REPO/stacks/mixed"
cp "$SMOKE" "$FAKE_REPO/script/smoke"
cp "$REPO"/bin/lib/*.sh "$FAKE_REPO/bin/lib/"
cp "$REPO/shared/linux/os" "$FAKE_REPO/shared/linux/os"
cp "$REPO/shared/darwin/os" "$FAKE_REPO/shared/darwin/os"
printf '# a declaration holding only commentary\n\n' > "$FAKE_REPO/stacks/hollow/tools"
printf 'ext|imagick|pecl\next|gd|bundled\n' > "$FAKE_REPO/stacks/extonly/tools"
printf 'tool|uv|uv|mise:uv|uv --version|python project manager\next|imagick|pecl\n' > "$FAKE_REPO/stacks/mixed/tools"
SMOKE_REAL="$SMOKE"; SMOKE="$FAKE_REPO/script/smoke"
MOCK_MANIFEST_STACK=hollow run_smoke hollow fedora
assert_rc       "a comment-only tools file → FAIL" 1
assert_contains "zero tool rows names the vacuous pass it prevents" "$(cat "$ERR")" "declares no tool rows"
MOCK_MANIFEST_STACK=extonly run_smoke extonly fedora
assert_rc       "an ext-only tools file → FAIL (ext rows carry no runtime probe)" 1
assert_contains "ext-only failure takes the zero-rows gate" "$(cat "$ERR")" "declares no tool rows"
MOCK_MANIFEST_STACK=mixed run_smoke mixed fedora
assert_rc       "a mixed tool+ext file → exit 0 (must-pass control)" 0
assert_probe_line "mixed file probes its tool row (exact remote command)" "uv --version"
assert_absent   "mixed file never probes an ext row" "$(cat "$CALLS")" "imagick"
# A malformed final row with an empty proof: command substitution strips the
# trailing blank line, so without the row-count guard the row would silently
# go unprobed and the run stay green — the exact false-green the guard closes.
printf 'tool|uv|uv|mise:uv|uv --version|python project manager\ntool|jq|jq|installer||broken row\n' > "$FAKE_REPO/stacks/mixed/tools"
MOCK_MANIFEST_STACK=mixed run_smoke mixed fedora
assert_rc       "a trailing empty-proof row → FAIL (row-count guard)" 1
assert_contains "row-count guard names the drop" "$(cat "$ERR")" "silently dropped"
# A whitespace-only proof is not empty to [ -z ] and a remote shell runs a
# blank command successfully — the probe loop's own guard must catch it.
printf 'tool|jq|jq|installer| |whitespace proof\ntool|uv|uv|mise:uv|uv --version|python project manager\n' > "$FAKE_REPO/stacks/mixed/tools"
MOCK_MANIFEST_STACK=mixed run_smoke mixed fedora
assert_rc       "a whitespace-only proof → FAIL" 1
assert_contains "whitespace-only proof names the vacuous green it prevents" "$(cat "$ERR")" "whitespace-only proof column"
SMOKE="$SMOKE_REAL"

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

# darwin platform: script/smoke resolves the OS token to a platform via
# tart_os_platform (bin/lib/common.sh) against the REAL shared/*/os — "macos"
# and "fedora" are both real tokens there, so no fixture glob is needed the
# way tart-new.sh's tests build one; every "fedora" run above already IS the
# must-pass control proving this gate does not block a real linux token.
echo "  -- darwin platform --"

# An OS token claimed by no platform (shared/*/os lists neither) is refused
# before tart-new ever runs — smoke must not clone against an unresolvable
# platform.
run_smoke php bogus-os
assert_rc       "unsupported OS token → FAIL before cloning" 1
assert_contains "unsupported OS names the refusal" "$(cat "$ERR")" "not claimed by exactly one platform"
assert_absent   "unsupported OS → tart-new never runs" "$(cat "$CALLS")" "tart-new"

# darwin has no DE axis — tart-new (Task 16) refuses a <de> too, but smoke
# catches it first so the failure reads as smoke's own, not a downstream
# tart-new error.
run_smoke php macos kde
assert_rc       "darwin <de> → FAIL before cloning" 1
assert_contains "darwin <de> refusal names the reason" "$(cat "$ERR")" "linux-only argument"
assert_absent   "darwin <de> refusal → tart-new never runs" "$(cat "$CALLS")" "tart-new"

# Happy path: darwin's guest self-ID, listener-surface, and Screen Sharing
# stages, plus the closing verdict line's platform-specific wording.
MOCK_MANIFEST_OS=macos MOCK_MANIFEST_SWVERSID=macos run_smoke php macos
assert_rc       "darwin happy path → exit 0" 0
assert_contains "darwin manifest read uses sw_vers, not os-release" "$(cat "$CALLS")" "sw_vers -productName"
assert_absent   "darwin manifest read never sources os-release"    "$(cat "$CALLS")" "/etc/os-release"
assert_contains "darwin verdict names the sw_vers attest"  "$(cat "$ERR")" "guest sw_vers id"
assert_absent   "darwin verdict never names os-release id" "$(cat "$ERR")" "guest os-release id"
assert_contains "darwin listener-table must-pass control"  "$(cat "$ERR")" "22 present (must-pass control)"
assert_contains "darwin screen-sharing ok line"             "$(cat "$ERR")" "screen sharing"
assert_contains "darwin listener-surface ok line"           "$(cat "$ERR")" ":22 alone beyond loopback (survived clone)"
assert_contains "darwin verdict names sw_vers, not os-release" "$(cat "$ERR")" "manifest, sw_vers, toolchain"
assert_absent   "darwin verdict never says os-release"      "$(cat "$ERR")" "os-release"
assert_contains "darwin verdict names the closing stages"   "$(cat "$ERR")" "sshd posture, listener surface, screen sharing"
assert_absent   "darwin run never touches the linux VNC surface" "$(cat "$CALLS")" "tart-stacks-vnc"

# Regression control: a plain linux run must never touch darwin's stage.
run_smoke php fedora
assert_absent   "linux run never touches darwin's netstat check" "$(cat "$CALLS")" "netstat -an -p tcp"

# guest sw_vers disagrees with the manifest → FAIL, same shape as linux's
# os-release-vs-manifest attest (guest self-ID stays independent of the
# manifest's own os:/os-pretty: fields either way).
MOCK_MANIFEST_OS=macos MOCK_MANIFEST_SWVERSID=ubuntu run_smoke php macos
assert_rc       "darwin guest sw_vers disagrees with manifest → FAIL" 1
assert_contains "sw_vers mismatch names both values" "$(cat "$ERR")" "expected 'macos', guest reports 'ubuntu'"

# darwin's manifest carries no gui: key — the attest must not even run there.
# A bogus gui: value would fail the attest instantly on linux (must-pass
# control: a mismatched value on linux DOES fail, per the existing "GUI image
# smoked as headless" test above) but must pass clean through a darwin run.
MOCK_MANIFEST_OS=macos MOCK_MANIFEST_SWVERSID=macos MOCK_MANIFEST_GUI=bogus-gui-value run_smoke php macos
assert_rc       "darwin never attests manifest gui: (no axis to check)" 0

# hostname-failure wording: darwin names scutil, never hostnamectl (tart-up
# has no hostnamectl branch on that platform — see bin/tart-up's own
# darwin_set_hostname). The linux wording's own must-pass control already
# exists above ("stale hostname offers the guest cause").
MOCK_MANIFEST_OS=macos MOCK_MANIFEST_SWVERSID=macos MOCK_TART_EXEC_HOSTNAME=stale-name run_smoke php macos
assert_rc       "darwin agent healthy but hostname stale → FAIL" 1
assert_contains "darwin stale-hostname names scutil"      "$(cat "$ERR")" "scutil failed in the guest"
assert_absent   "darwin stale-hostname never names hostnamectl" "$(cat "$ERR")" "hostnamectl/systemd-hostnamed"

# Screen Sharing present on :5900 → FAIL, naming the concrete threat.
MOCK_MANIFEST_OS=macos MOCK_MANIFEST_SWVERSID=macos \
  MOCK_NETSTAT_LISTENERS="$(printf 'tcp4 0 0 *.22 *.* LISTEN\ntcp4 0 0 *.5900 *.* LISTEN')" \
  run_smoke php macos
assert_rc       "darwin Screen Sharing listening → FAIL" 1
assert_contains "Screen Sharing failure names the service" "$(cat "$ERR")" "Screen Sharing"
assert_contains "Screen Sharing failure names the threat"  "$(cat "$ERR")" "admin/admin"

# A LOOPBACK-bound :5900 is the only case this gate catches that the general
# non-loopback check below does not — every other shape trips that one too, so
# without this row the Screen Sharing gate could be deleted outright and the
# suite would stay green on the strength of its neighbour. The bind is
# deliberately not tolerated the way an operator's RemoteForward is: nothing
# legitimately forwards a tunnel onto :5900, so its appearance means the base's
# disabled service came back.
MOCK_MANIFEST_OS=macos MOCK_MANIFEST_SWVERSID=macos \
  MOCK_NETSTAT_LISTENERS="$(printf 'tcp4 0 0 *.22 *.* LISTEN\ntcp4 0 0 127.0.0.1.5900 *.* LISTEN')" \
  run_smoke php macos
assert_rc       "darwin LOOPBACK-bound :5900 → FAIL (not excused as a tunnel)" 1
assert_contains "loopback :5900 failure still names Screen Sharing" "$(cat "$ERR")" "Screen Sharing"

# An unexpected port that is NOT Screen Sharing (e.g. the base's Kerberos KDC
# on :88) must still fail the general :22-alone claim, naming the port.
MOCK_MANIFEST_OS=macos MOCK_MANIFEST_SWVERSID=macos \
  MOCK_NETSTAT_LISTENERS="$(printf 'tcp4 0 0 *.22 *.* LISTEN\ntcp4 0 0 *.88 *.* LISTEN')" \
  run_smoke php macos
assert_rc       "darwin unexpected non-5900 port → FAIL" 1
assert_contains "unexpected-port failure names :22-alone" "$(cat "$ERR")" "non-loopback listener beyond :22"
assert_contains "unexpected-port failure names the port"  "$(cat "$ERR")" "88"

# The real-gate regression: a `Host tart-* RemoteForward …` block in
# ~/.config/tart-stacks/forwards makes sshd-sess bind the forwarded port on
# the GUEST's loopback for the life of the operator's ssh session — real
# sockets on 127.0.0.1/::1, not exposure. Both families (v4 loopback, v6
# loopback), both operator ports (4445, 8080) from the real failure, MUST
# still pass. Fixture format measured directly against the real `netstat -an
# -p tcp` binary (macOS host) — IPv6 loopback prints unbracketed (`::1.PORT`),
# NOT `[::1].PORT`; a bracketed fixture here would pass against code that
# can't actually classify the real guest's output (round-1 mistake: both the
# fixture and the classifier were wrong the same way, so the test proved
# nothing).
MOCK_MANIFEST_OS=macos MOCK_MANIFEST_SWVERSID=macos \
  MOCK_NETSTAT_LISTENERS="$(printf 'tcp4 0 0 *.22 *.* LISTEN\ntcp4 0 0 127.0.0.1.4445 *.* LISTEN\ntcp6 0 0 ::1.4445 *.* LISTEN\ntcp4 0 0 127.0.0.1.8080 *.* LISTEN\ntcp6 0 0 ::1.8080 *.* LISTEN')" \
  run_smoke php macos
assert_rc       "darwin loopback-bound RemoteForward ports → smoke PASSES" 0
assert_contains "loopback-forward run still reports the listener-surface ok line" "$(cat "$ERR")" ":22 alone beyond loopback"

# The same ports on a NON-loopback bind (e.g. GatewayPorts, or a forward gone
# wrong) must still fail — the classifier reads the actual bind address off
# each row, not "is this port one of the known forward numbers".
MOCK_MANIFEST_OS=macos MOCK_MANIFEST_SWVERSID=macos \
  MOCK_NETSTAT_LISTENERS="$(printf 'tcp4 0 0 *.22 *.* LISTEN\ntcp4 0 0 *.4445 *.* LISTEN')" \
  run_smoke php macos
assert_rc       "darwin non-loopback bind on a forward's OWN port → FAIL" 1
assert_contains "non-loopback forward-port failure names the address" "$(cat "$ERR")" "*:4445"

# must-pass control: an empty/broken listener-table read that still exits 0
# must not pass either claim vacuously — :22 has to show up in the parsed set
# on its own for either downstream claim to be trustworthy.
MOCK_MANIFEST_OS=macos MOCK_MANIFEST_SWVERSID=macos MOCK_NETSTAT_LISTENERS='' run_smoke php macos
assert_rc       "darwin empty listener table → FAIL (must-pass control)" 1
assert_contains "empty table names the missing must-pass control" "$(cat "$ERR")" "never showed :22 itself"

# The read itself failing (e.g. sudo denied) is a distinct verdict from "the
# table has no extra port" — one is a defective image, the other unverified.
MOCK_MANIFEST_OS=macos MOCK_MANIFEST_SWVERSID=macos MOCK_NETSTAT_RC=1 run_smoke php macos
assert_rc       "darwin netstat read failure → FAIL" 1
assert_contains "netstat read failure says unverified" "$(cat "$ERR")" "unverified"

printf '\n  %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
