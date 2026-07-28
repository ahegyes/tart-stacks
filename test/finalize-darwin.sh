#!/usr/bin/env bash
# Behavioral + characterization tests for shared/darwin/scripts/99-finalize.sh.
#
# HOST SAFETY: this suite runs on the owner's own Mac. The shipped script
# disables real launchd services, deletes real SSH host keys, and writes a
# root-owned sshd drop-in — none of that may ever touch the real system here.
# Two techniques keep it that way, matching precedent already on this branch:
#
#   1. The runtime-observable region (integrity re-check, package cache
#      clean, the two service disables, CI-artifact removal, the NOPASSWD
#      sudo assert, the listener assert, and the manifest write) is lifted
#      out of the SHIPPED script with awk — same technique test/base-
#      darwin.sh uses — and run for real against a synthetic root via
#      TART_ROOT, with every privileged/system command (launchctl, netstat,
#      csrutil, sw_vers) PATH-mocked and its argv logged, same technique
#      test/user-config-darwin.sh uses. assert_integrity_enforced,
#      pkg_clean, and assert_nopasswd_sudo are stubbed exactly as
#      test/base-darwin.sh stubs assert_release_supported /
#      install_guest_agent, so the calls stay measurable rather than
#      merely present — assert_nopasswd_sudo's own accept/refuse behavior is
#      covered directly against family-lib.sh in test/family-lib-darwin.sh,
#      not re-tested here.
#   2. The SSH-key-gate wiring (source the shared lib, call it with the
#      pinned literal path, ordering relative to the key install) AND the
#      host-key deletion are NEVER executed — both are checked statically
#      against the shipped script's text, exactly as test/finalize-linux.sh
#      does for the linux peer. That region writes a root-owned file, calls
#      `install -o root`, and runs `sshd -t`, none of which a non-root test
#      process can do (`sshd -t` needs to read real, root-owned host keys —
#      confirmed empirically: as a normal user it exits "no hostkeys
#      available" regardless of what this script did). Host-key deletion
#      lives here, AFTER `sshd -t`, specifically because `sshd -t` loads the
#      host keys to validate the sshd config — deleting them earlier made a
#      real build fail at this exact step ("no hostkeys available -- exiting"),
#      which is what the ordering check below exists to catch. Nothing here
#      re-tests the key gate's own accept/refuse behavior, which
#      test/authorized-key-lib.sh already owns.
#
# Plain bash, no framework.
set -uo pipefail

TEST_DIR=$(cd -P "$(dirname "$0")" >/dev/null 2>&1 && pwd)
REPO=$(cd -P "$TEST_DIR/.." >/dev/null 2>&1 && pwd)
FINALIZE="$REPO/shared/darwin/scripts/99-finalize.sh"

pass=0 fail=0
ok()  { pass=$((pass + 1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  FAIL %s\n         %s\n' "$1" "${2:-}"; }
assert_eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "want » $2 « got » $3 «"; fi; }
assert_contains() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "want » $3 « in: $2" ;; esac; }
assert_not_contains() { case "$2" in *"$3"*) bad "$1" "did NOT want » $3 « in: $2" ;; *) ok "$1" ;; esac; }

# ════════════════════════════════════════════════════════════════════════
# Part 1 — the SSH-key-gate wiring: static, never executed (see header).
# ════════════════════════════════════════════════════════════════════════
echo "99-finalize (darwin) — sources and calls the shared gate, not a reimplementation:"
if grep -qF 'source /tmp/authorized-key-lib.sh' "$FINALIZE"; then
  ok "sources /tmp/authorized-key-lib.sh"
else
  bad "sources /tmp/authorized-key-lib.sh" "no matching source line found"
fi
# Pinned to the literal path, not a wildcard: a wildcard here let a
# wrong-path caller regression pass the whole linux suite until it was
# caught (commit 2624054) — the same class of gap must not recur on darwin.
if grep -qE '^assert_authorized_key_safe /tmp/authorized_key\.pub \|\| exit 1$' "$FINALIZE"; then
  ok "calls assert_authorized_key_safe /tmp/authorized_key.pub || exit 1"
else
  bad "calls assert_authorized_key_safe /tmp/authorized_key.pub || exit 1" "no matching call found"
fi
# The gate's own logic must live in the library, not be pasted back in here
# — a reimplementation would silently drift from what test/authorized-key-
# lib.sh actually proves against.
if grep -q -- '-----BEGIN .*PRIVATE KEY-----' "$FINALIZE"; then
  bad "does not reimplement the PEM-armor check inline" \
      "found the armor pattern in $FINALIZE — the gate belongs in authorized-key-lib.sh"
else
  ok "does not reimplement the PEM-armor check inline"
fi
if grep -q -- 'ssh-keygen -l -f' "$FINALIZE"; then
  bad "does not reimplement the parse check inline" \
      "found a direct ssh-keygen -l -f call in $FINALIZE — the gate belongs in authorized-key-lib.sh"
else
  ok "does not reimplement the parse check inline"
fi

echo "99-finalize (darwin) — the gate precedes the install, which precedes the sshd drop-in:"
line_re() { grep -nE -- "$1" "$FINALIZE" | head -n1 | cut -d: -f1; }
line_of() { grep -nF -- "$1" "$FINALIZE" | head -n1 | cut -d: -f1; }
gate_line=$(line_re '^assert_authorized_key_safe /tmp/authorized_key\.pub \|\| exit 1$')
install_line=$(line_of '.ssh/authorized_keys')
# There is no passwd -l on darwin (the password stays unlocked — see the
# manifest's password: line) — the sshd drop-in disabling password auth is
# the closest thing this platform has to an irreversible step downstream of
# the key install, so it is what the ordering chain protects here.
sshd_dropin_line=$(line_of 'sshd_config.d/00-vm-hardening.conf')
check_order() { # <earlier-label> <earlier-line> <later-label> <later-line>
  if [ -n "$2" ] && [ -n "$4" ] && [ "$2" -lt "$4" ]; then
    ok "$1 (line $2) precedes $3 (line $4)"
  else
    bad "$1 precedes $3" "got $1=${2:-absent}, $3=${4:-absent}"
  fi
}
check_order "the authorized-key gate"     "$gate_line"    "the authorized_keys install" "$install_line"
check_order "the authorized_keys install" "$install_line" "the sshd drop-in write"      "$sshd_dropin_line"

# Ordering guard (fix round 3): a real build reached this script and failed
# at the very last step — `sshd -t` exited "no hostkeys available" because
# host-key deletion ran BEFORE it, not after. `sshd -t` loads the host keys
# to validate the config, so it must precede their removal; this is a
# property of the script's TEXT (the same class of check as the gate/install/
# sshd-drop-in chain above), not something the runtime region in Part 2 can
# catch — that region stops before this code even runs, by design (see the
# header comment).
echo
echo "99-finalize (darwin) — sshd -t precedes the host-key removal it depends on:"
sshd_t_line=$(line_re '^sshd -t$')
host_key_rm_line=$(line_of 'ssh_host_*_key')
check_order "sshd -t" "$sshd_t_line" "the host-key removal" "$host_key_rm_line"

# Host-safety regression guard (fix round 2, item 2): the coordinator caught
# these two staging paths unprefixed and empirically confirmed a planted
# sentinel at the REAL /tmp/tart-stacks-tools / /tmp/tart-stacks-skipped got
# deleted by a run of this very suite — invisible to every assertion below,
# since those only ever look under a synthetic TART_ROOT. A static text
# check is what actually closes that hole: no execution-based case can prove
# a negative about the real filesystem the way "grep found zero unprefixed
# occurrences" can. total == prefixed for BOTH names means every reference
# in the shipped script carries the ${TART_ROOT} prefix — not just the ones
# this suite happens to exercise.
echo
echo "99-finalize (darwin) — the /tmp staging-file paths are TART_ROOT-prefixed everywhere they appear:"
for base in tart-stacks-tools tart-stacks-skipped; do
  total=$(grep -c "/tmp/${base}" "$FINALIZE")
  prefixed=$(grep -c '\${TART_ROOT}/tmp/'"${base}" "$FINALIZE")
  assert_eq "every /tmp/${base} reference (${total} found) is \${TART_ROOT}-prefixed" "$total" "$prefixed"
done

# ════════════════════════════════════════════════════════════════════════
# Part 2 — the runtime-observable region: lifted out and run for real.
# ════════════════════════════════════════════════════════════════════════
WORK=$(mktemp -d); MOCKBIN="$WORK/bin"; install -d "$MOCKBIN"
trap 'rm -rf "$WORK"' EXIT

# launchctl — MUST be mocked (host safety: the shipped call disables the
# owner's real Screen Sharing and boots out the real Kerberos KDC). Logging
# the full argv is the control that proves the MOCK ran with the argv the
# script actually sent, not merely that a same-named binary didn't explode.
cat > "$MOCKBIN/launchctl" <<'M'
#!/usr/bin/env bash
[ -n "${MOCK_LOG:-}" ] && printf 'launchctl %s\n' "$*" >> "$MOCK_LOG"
exit 0
M

# netstat — mocked so the listener assertion is driven by a controlled
# fixture rather than whatever happens to be listening on the tester's own
# Mac. Emits one LISTEN row per port in MOCK_LISTEN_PORTS (default: 22
# alone — the must-pass control), in the same column shape real macOS
# netstat -an -p tcp uses, since the script's awk keys off $4 and $NF.
cat > "$MOCKBIN/netstat" <<'M'
#!/usr/bin/env bash
[ -n "${MOCK_LOG:-}" ] && printf 'netstat %s\n' "$*" >> "$MOCK_LOG"
echo "Active Internet connections (including servers)"
echo "Proto Recv-Q Send-Q  Local Address          Foreign Address        (state)"
for p in ${MOCK_LISTEN_PORTS:-22}; do
  printf 'tcp4       0      0  *.%s                   *.*                    LISTEN\n' "$p"
done
M

# csrutil — mocked for determinism (real output depends on the tester's own
# SIP/SSV state, which must not decide a test's verdict) and to prove the
# manifest's sip:/ssv: lines are LIVE-read, not hardcoded — cases below flip
# MOCK_SIP/MOCK_SSV and assert the manifest tracks them.
cat > "$MOCKBIN/csrutil" <<'M'
#!/usr/bin/env bash
case "$1" in
  authenticated-root) printf 'Authenticated Root status: %s.\n' "${MOCK_SSV:-enabled}" ;;
  *)                  printf 'System Integrity Protection status: %s.\n' "${MOCK_SIP:-disabled}" ;;
esac
M

# sw_vers — mocked for the same reason: the manifest's os-pretty: line must
# be provably LIVE-read, not a hardcoded string, and must not vary with
# whatever macOS version happens to be running this suite.
cat > "$MOCKBIN/sw_vers" <<'M'
#!/usr/bin/env bash
case "${1:-}" in
  -productName)    printf '%s\n' "${MOCK_OS_NAME:-macOS}" ;;
  -productVersion)  printf '%s\n' "${MOCK_OS_VER:-26.5}" ;;
  -buildVersion)    printf '%s\n' "${MOCK_OS_BUILD:-25F84}" ;;
  *) exit 1 ;;
esac
M
chmod +x "$MOCKBIN"/launchctl "$MOCKBIN"/netstat "$MOCKBIN"/csrutil "$MOCKBIN"/sw_vers

# The window opens right after the SECOND source line (authorized-key-lib.sh
# — family-lib.sh's is skipped over the same way, since `open` isn't set
# until this landmark) and closes at the key-gate call, which Part 1 above
# owns statically. That boundary is deliberate, not incidental: everything
# in the window can run as a non-root test process against a synthetic
# TART_ROOT; everything after it (install -o root, the sshd drop-in, sshd
# -t reading real host keys) cannot.
GATE="$WORK/gate.sh"
{
  printf 'set -euo pipefail\n'
  # Controllable stubs, exactly as test/base-darwin.sh stubs
  # assert_release_supported/install_guest_agent: a status knob rather than
  # a fixed 0 so the CALL stays measurable — deleting the call from
  # 99-finalize.sh would otherwise go unnoticed with a fixed-success stub.
  # shellcheck disable=SC2016
  printf 'assert_integrity_enforced() { return "${MOCK_INTEGRITY_RC:-0}"; }\n'
  printf 'pkg_clean() { :; }\n'
  # shellcheck disable=SC2016
  printf 'assert_nopasswd_sudo() { return "${MOCK_SUDOERS_RC:-0}"; }\n'
  awk '
    /^source \/tmp\/authorized-key-lib\.sh$/ { open = 1; next }
    /^assert_authorized_key_safe \/tmp\/authorized_key\.pub \|\| exit 1$/ { if (open) exit }
    open { print }
  ' "$FINALIZE"
} > "$GATE"

echo
echo "99-finalize (darwin) — the runtime region was actually lifted out of the script:"
if grep -q 'one listener, key-only' "$GATE" && grep -q 'screensharingd' "$GATE"; then
  ok "lifted the service-disable through listener-assert region ($(grep -c . "$GATE") lines)"
else
  bad "lifted the service-disable through listener-assert region" \
      "extraction produced $(grep -c . "$GATE") line(s) — the region moved, or the awk anchors no longer match it"
  printf '\n  %d passed, %d failed\n' "$pass" "$fail"
  exit 1
fi

# setup_root <dir> — the tree a real macOS guest already has before this,
# the LAST provisioner, ever runs: /etc (the manifest write's parent dir),
# the build user's home (with a CI runner checkout inside it, directory-
# shaped), and a top-level /Users/runner. No ssh_host_* fixtures — host-key
# removal now lives in the never-executed region (see the header comment and
# the ordering guard in Part 1), so nothing in Part 2 reads or removes them.
# Two DIFFERENT shapes for /Users/runner across the suite (directory here, a
# plain file in the dedicated case below) is what proves the removal
# survives either — `rm -f` on a directory aborts under set -e, which the
# brief's literal form would have hit on one of the two.
setup_root() { # <dir> [runner-shape: dir|file]
  install -d -m 755 "$1/etc" "$1/Users/admin/actions-runner"
  : > "$1/Users/admin/actions-runner/run.sh"
  if [ "${2:-dir}" = "file" ]; then
    : > "$1/Users/runner"
  else
    install -d -m 755 "$1/Users/runner"
    : > "$1/Users/runner/.bash_profile"
  fi
}

# invoke_gate <root> <log> [env...] — run the SHIPPED (lifted) region for
# real; rc via $?. STACK/OS mirror the environment_vars Packer supplies.
# `env` is what actually applies the trailing MOCK_* assignments: a
# VAR=val WORD produced by expanding "$@" is not recognized by bash as a
# prefix assignment the way one written literally in source is — same
# technique test/family-lib-darwin.sh uses for the same reason.
invoke_gate() {
  local root="$1" log="$2"; shift 2
  env PATH="$MOCKBIN:$PATH" TART_ROOT="$root" SUDO_USER=admin MOCK_LOG="$log" \
    STACK=php OS=macos "$@" \
    bash "$GATE" >"$root/stdout" 2>"$root/stderr"
}

# ── the healthy run: every must-pass control in one place ──────────────────
# Without this case, an assertion that refuses unconditionally would pass
# every refusal case below for the wrong reason.
echo
echo "99-finalize (darwin) — the healthy run (every control that must PASS):"
WORK1="$WORK/w1"; install -d "$WORK1"; setup_root "$WORK1" dir
LOG1="$WORK1/log"
rc=0
invoke_gate "$WORK1" "$LOG1" MOCK_LISTEN_PORTS=22 MOCK_SIP=disabled MOCK_SSV=enabled || rc=$?
assert_eq "exits 0 against a healthy fixture" 0 "$rc"
[ "$rc" -eq 0 ] || cat "$WORK1/stderr" >&2

echo "99-finalize (darwin) — remote-access services (positive control: the mock, not the real system, ran):"
LOGGED1=$(cat "$LOG1")
assert_contains "disables Screen Sharing"        "$LOGGED1" "launchctl disable system/com.apple.screensharing"
assert_contains "boots out Screen Sharing"        "$LOGGED1" "launchctl bootout system/com.apple.screensharing"
assert_contains "disables the Kerberos KDC"       "$LOGGED1" "launchctl disable system/com.apple.Kerberos.kdc"
assert_contains "boots out the Kerberos KDC"      "$LOGGED1" "launchctl bootout system/com.apple.Kerberos.kdc"

echo "99-finalize (darwin) — CI runner artifacts (directory shape):"
if [ ! -e "$WORK1/Users/admin/actions-runner" ]; then ok "actions-runner directory removed"; else bad "actions-runner directory removed" "still present"; fi
if [ ! -e "$WORK1/Users/runner" ]; then ok "/Users/runner directory removed"; else bad "/Users/runner directory removed" "still present"; fi

echo "99-finalize (darwin) — the listener assert PASSES when :22 is the only listener (must-pass control):"
assert_contains "netstat was reached (the mock, not the real system)" "$LOGGED1" "netstat -an -p tcp"

echo "99-finalize (darwin) — the manifest:"
MANIFEST="$WORK1/etc/tart-stacks-release"
if [ -f "$MANIFEST" ]; then ok "manifest written"; else bad "manifest written" "no file at $MANIFEST"; fi
MC=$(cat "$MANIFEST" 2>/dev/null)
assert_contains "names the build token"   "$MC" "os: macos"
assert_contains "names platform: darwin"  "$MC" "platform: darwin"
assert_contains "names support-end: none" "$MC" "support-end: none"
assert_contains "records the password posture" "$MC" "password: unlocked"
os_lines=$(printf '%s\n' "$MC" | awk '$1=="os:" { c++ } END { print c+0 }')
assert_eq "exactly one os: line (the field a clone/smoke reads)" "1" "$os_lines"
assert_contains "sip: is live-read from the mock, not hardcoded" "$MC" "sip: disabled"
assert_contains "ssv: is live-read from the mock, not hardcoded" "$MC" "ssv: enabled"
assert_contains "os-pretty: is live-read from the sw_vers mock"  "$MC" "os-pretty: macOS 26.5 (25F84)"

# ── a DIFFERENT csrutil/sw_vers answer must show up differently — proves the
#    fields above are wired to the mock, not a string this script hardcodes.
echo
echo "99-finalize (darwin) — manifest fields track a DIFFERENT mock answer (not hardcoded):"
WORK2="$WORK/w2"; install -d "$WORK2"; setup_root "$WORK2" dir
LOG2="$WORK2/log"
rc=0
invoke_gate "$WORK2" "$LOG2" MOCK_LISTEN_PORTS=22 MOCK_SIP=enabled MOCK_SSV=enabled \
  MOCK_OS_NAME=macOS MOCK_OS_VER=27.0 MOCK_OS_BUILD=99Z999 || rc=$?
assert_eq "still exits 0" 0 "$rc"
MC2=$(cat "$WORK2/etc/tart-stacks-release" 2>/dev/null)
assert_contains "sip: flips to the new mock answer" "$MC2" "sip: enabled"
assert_contains "os-pretty: flips to the new mock answer" "$MC2" "os-pretty: macOS 27.0 (99Z999)"

# ── the /Users/runner FILE shape (the brief's literal form would abort here) ─
echo
echo "99-finalize (darwin) — /Users/runner as a plain FILE is also removed without aborting the build:"
WORK3="$WORK/w3"; install -d "$WORK3"; setup_root "$WORK3" file
LOG3="$WORK3/log"
rc=0
invoke_gate "$WORK3" "$LOG3" MOCK_LISTEN_PORTS=22 || rc=$?
assert_eq "exits 0 with /Users/runner as a file" 0 "$rc"
[ "$rc" -eq 0 ] || cat "$WORK3/stderr" >&2
if [ ! -e "$WORK3/Users/runner" ]; then ok "/Users/runner file removed"; else bad "/Users/runner file removed" "still present"; fi

# ── an extra listener fails the build and names the port ───────────────────
echo
echo "99-finalize (darwin) — an extra listener fails the build:"
WORK4="$WORK/w4"; install -d "$WORK4"; setup_root "$WORK4" dir
LOG4="$WORK4/log"
rc=0
invoke_gate "$WORK4" "$LOG4" MOCK_LISTEN_PORTS="22 5900" || rc=$?
assert_eq "a non-:22 listener refuses the build" "1" "$rc"
assert_contains "names the offending port" "$(cat "$WORK4/stderr")" "5900"

# ── the integrity re-check is actually called, not merely defined ──────────
echo
echo "99-finalize (darwin) — the integrity re-check can fail the build on its own:"
WORK5="$WORK/w5"; install -d "$WORK5"; setup_root "$WORK5" dir
LOG5="$WORK5/log"
rc=0
invoke_gate "$WORK5" "$LOG5" MOCK_LISTEN_PORTS=22 MOCK_INTEGRITY_RC=1 || rc=$?
assert_eq "a regressed integrity posture refuses the build" "1" "$rc"

# ── the NOPASSWD sudo assertion is actually called, not merely defined ─────
# assert_nopasswd_sudo's own accept/refuse logic (missing file, malformed
# syntax) is covered directly against the library in
# test/family-lib-darwin.sh; this case only proves 99-finalize.sh actually
# CALLS it — a deleted call would otherwise go unnoticed with a stub that
# always returns success.
echo
echo "99-finalize (darwin) — the NOPASSWD sudo assertion can fail the build on its own:"
WORK6="$WORK/w6"; install -d "$WORK6"; setup_root "$WORK6" dir
LOG6="$WORK6/log"
rc=0
invoke_gate "$WORK6" "$LOG6" MOCK_LISTEN_PORTS=22 MOCK_SUDOERS_RC=1 || rc=$?
assert_eq "a missing/invalid NOPASSWD drop-in refuses the build" "1" "$rc"

printf '\n  %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
