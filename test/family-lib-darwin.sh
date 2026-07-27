#!/usr/bin/env bash
# Characterization + behavioral tests for family-lib.sh (darwin): the brew
# package abstraction plus its two build-time assertions. This suite runs on
# a real macOS host, so csrutil/sw_vers/sudo/uname are the machine's own
# binaries — every case that must not reach the real one puts a matching
# mock ahead on PATH. No framework; same technique test/family-lib-linux.sh
# uses (mocked binaries on PATH, subshell-scoped env, counted verdicts).
set -uo pipefail
TEST_DIR=$(cd -P "$(dirname "$0")" >/dev/null 2>&1 && pwd); REPO=$(cd -P "$TEST_DIR/.." >/dev/null 2>&1 && pwd)
LIB="$REPO/shared/darwin/scripts/family-lib.sh"
pass=0 fail=0
ok(){ pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  FAIL %s\n         %s\n' "$1" "${2:-}"; }
assert_eq(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "want » $2 « got » $3 «"; fi; }
assert_contains(){ case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "want » $3 « in: $2" ;; esac; }
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
MOCKBIN="$WORK/bin"; mkdir -p "$MOCKBIN"

# _brew's only escalation path. Logging the whole argv (not just "brew ...")
# is what proves the privilege drop happens ahead of the package manager,
# not merely that brew was eventually invoked. MOCK_SUDO_FAIL matches
# against the LAST argument (the formula name, for both `install` and `list
# --formula`), so a single mock covers both the "unavailable package" and
# the "installed?" probes.
cat > "$MOCKBIN/sudo" <<'M'
#!/usr/bin/env bash
[ -n "${MOCK_LOG:-}" ] && printf '%s\n' "$*" >> "$MOCK_LOG"
last="${!#}"
[ -n "${MOCK_SUDO_FAIL:-}" ] && [ "$last" = "$MOCK_SUDO_FAIL" ] && exit 1
exit 0
M

# assert_integrity_enforced must call `csrutil authenticated-root status`
# SPECIFICALLY, not the bare `csrutil status` combined report — every Cirrus
# base ships SIP disabled, so an implementation keyed off that combined
# report (or off SIP at all) would refuse every build it should pass. The
# default response shape (SSV enabled, SIP disabled) IS that normal case.
cat > "$MOCKBIN/csrutil" <<'M'
#!/usr/bin/env bash
[ "${MOCK_CSRUTIL_RC:-0}" = "0" ] || exit "$MOCK_CSRUTIL_RC"
case "$1" in
  authenticated-root) printf 'Authenticated Root status: %s.\n' "${MOCK_SSV:-enabled}" ;;
  *)                  printf 'System Integrity Protection status: %s.\n' "${MOCK_SIP:-disabled}" ;;
esac
M

cat > "$MOCKBIN/sw_vers" <<'M'
#!/usr/bin/env bash
[ "${1:-}" = "-productVersion" ] && { printf '%s\n' "${MOCK_MACOS_VER:-26.0}"; exit 0; }
exit 1
M

# Defaults to the real answer (Darwin) so every OTHER case that puts
# MOCKBIN on PATH behaves exactly as it would with the real uname; only the
# wrong-platform case below overrides it.
cat > "$MOCKBIN/uname" <<'M'
#!/usr/bin/env bash
[ "${1:-}" = "-s" ] && { printf '%s\n' "${MOCK_UNAME_S:-Darwin}"; exit 0; }
exit 1
M
chmod +x "$MOCKBIN/sudo" "$MOCKBIN/csrutil" "$MOCKBIN/sw_vers" "$MOCKBIN/uname"

# ── _detect_family ───────────────────────────────────────────────────────────
echo "family-lib (darwin) — _detect_family:"
# shellcheck source=/dev/null
fam_out=$( ( source "$LIB"; printf '%s' "$_TART_FAMILY" ) )
assert_eq "the only family is brew" "brew" "$fam_out"

# Both platforms' libraries upload to the same /tmp/family-lib.sh; the one
# way this file ever runs on the wrong guest is a build-config mistake, and
# that must hard-exit rather than silently guess a family.
wrong_platform_rc() {
  local rc=0
  # shellcheck disable=SC2016  # $1 is bash -c's own argument, not this shell's
  env PATH="$MOCKBIN:$PATH" MOCK_UNAME_S=Linux \
    bash -c '. "$1"' _ "$LIB" >/dev/null 2>&1 || rc=$?
  printf '%s' "$rc"
}
assert_eq "a non-Darwin guest hard-exits rather than guessing a family" 1 "$(wrong_platform_rc)"

# ── pkg_install ───────────────────────────────────────────────────────────────
# THE case this library exists for: brew refuses to run as root, so the
# abstraction must drop privileges itself, and every package must arrive in
# one call (not one sudo invocation per formula).
echo
echo "family-lib (darwin) — pkg_install:"
LOG="$WORK/sudo-log"
# shellcheck disable=SC2030  # the subshell-scoped env IS the sandbox
( export PATH="$MOCKBIN:$PATH" MOCK_LOG="$LOG" TART_BUILD_USER=admin
  # shellcheck source=/dev/null
  source "$LIB"
  pkg_install jq zellij ) >/dev/null 2>&1
assert_contains "drops privileges to the build user" "$(cat "$LOG")" "-u admin"
assert_contains "passes every package in ONE call" "$(cat "$LOG")" "brew install jq zellij"

LOG_EMPTY="$WORK/sudo-log-empty"
# shellcheck disable=SC2030,SC2031  # the subshell-scoped env IS the sandbox
( export PATH="$MOCKBIN:$PATH" MOCK_LOG="$LOG_EMPTY" TART_BUILD_USER=admin
  # shellcheck source=/dev/null
  source "$LIB"
  pkg_install ) >/dev/null 2>&1
assert_eq "an empty argv never reaches brew install" "" "$(cat "$LOG_EMPTY" 2>/dev/null)"

# ── pkg_install_optional ──────────────────────────────────────────────────────
echo
echo "family-lib (darwin) — pkg_install_optional:"
SKIP="$WORK/skipped"
# shellcheck disable=SC2030,SC2031  # the subshell-scoped env IS the sandbox
( export PATH="$MOCKBIN:$PATH" TART_SKIPPED_FILE="$SKIP" MOCK_SUDO_FAIL="gone-formula"
  # shellcheck source=/dev/null
  source "$LIB"
  pkg_install_optional kept-formula gone-formula ) >/dev/null 2>&1
assert_eq "only the unavailable formula is recorded" "gone-formula" "$(cat "$SKIP" 2>/dev/null)"

# ── assert_integrity_enforced ─────────────────────────────────────────────────
# Its whole job is to fail a build, so an untested one can only be
# discovered by shipping an image whose sealed system volume had silently
# regressed.
echo
echo "family-lib (darwin) — assert_integrity_enforced:"
int_err=""
int_rc() {  # KEY=VALUE ... — exit status of assert_integrity_enforced
  local rc=0
  # shellcheck disable=SC2030,SC2031  # the subshell-scoped env IS the sandbox
  # shellcheck disable=SC2163  # "$@" carries literal KEY=VALUE pairs, which is
  # exactly what export takes as operands — not an indirect variable name
  int_err=$( ( export PATH="$MOCKBIN:$PATH" "$@"
               # shellcheck source=/dev/null
               source "$LIB"
               assert_integrity_enforced ) 2>&1 ) || rc=$?
  printf '%s' "$rc"
}
assert_eq "a disabled SSV refuses the build"                 1 "$(int_rc MOCK_SSV=disabled)"
# The normal case for every Cirrus base: SIP is off, SSV is on. A test suite
# that only covered the refusal above would let an implementation that
# gates on SIP instead of SSV through — it would coincidentally also refuse
# the disabled-SSV case (SIP is disabled there too), then fail EVERY build.
assert_eq "SSV enabled passes even though SIP is disabled"   0 "$(int_rc MOCK_SSV=enabled MOCK_SIP=disabled)"
# A query that errors leaves the posture unknown, which must not read as fine.
assert_eq "an unavailable csrutil refuses (fails closed)"    1 "$(int_rc MOCK_CSRUTIL_RC=1)"
int_rc MOCK_SSV=disabled >/dev/null
assert_contains "the refusal names the mechanism" "$int_err" "signed system volume"

# ── assert_release_supported ──────────────────────────────────────────────────
echo
echo "family-lib (darwin) — assert_release_supported:"
rel_err=""
rel_rc() {  # KEY=VALUE ...
  local rc=0
  # shellcheck disable=SC2030,SC2031  # the subshell-scoped env IS the sandbox
  # shellcheck disable=SC2163  # "$@" carries literal KEY=VALUE pairs, which is
  # exactly what export takes as operands — not an indirect variable name
  rel_err=$( ( export PATH="$MOCKBIN:$PATH" "$@"
               # shellcheck source=/dev/null
               source "$LIB"
               assert_release_supported ) 2>&1 ) || rc=$?
  printf '%s' "$rc"
}
assert_eq "a guest older than the pin is refused" 1 "$(rel_rc MOCK_MACOS_VER=25.0 MACOS_TARGET_RELEASE=26)"
assert_eq "a guest matching the pin passes"       0 "$(rel_rc MOCK_MACOS_VER=26.0 MACOS_TARGET_RELEASE=26)"
assert_eq "a guest newer than the pin passes"     0 "$(rel_rc MOCK_MACOS_VER=27.3 MACOS_TARGET_RELEASE=26)"
assert_eq "an unreadable version is refused"      1 "$(rel_rc MOCK_MACOS_VER=notaversion MACOS_TARGET_RELEASE=26)"
rel_rc MOCK_MACOS_VER=25.0 MACOS_TARGET_RELEASE=26 >/dev/null
assert_contains "the refusal names the guest's version" "$rel_err" "macOS 25"
assert_contains "the refusal names the pin to lower"     "$rel_err" "MACOS_TARGET_RELEASE=26"

# ── install_guest_agent ────────────────────────────────────────────────────────
# tart exec is served by the per-user AGENT, not the root daemon, so both
# halves matter: an image carrying only the daemon still answers ssh, and
# would otherwise look identical to a healthy one until tart-up's hostname
# step (or any tart exec call) fails against it.
echo
echo "family-lib (darwin) — install_guest_agent:"
DAEMON="$WORK/tart-guest-daemon.plist"; AGENT="$WORK/tart-guest-agent.plist"
: > "$DAEMON"; : > "$AGENT"
agent_err=""
agent_rc() {  # <daemon-plist> <agent-plist>
  local rc=0
  agent_err=$( ( export TART_GUEST_DAEMON_PLIST="$1" TART_GUEST_AGENT_PLIST="$2"
                 # shellcheck source=/dev/null
                 source "$LIB"
                 install_guest_agent ) 2>&1 ) || rc=$?
  printf '%s' "$rc"
}
assert_eq "both components present passes"    0 "$(agent_rc "$DAEMON" "$AGENT")"
assert_eq "a missing daemon plist is refused" 1 "$(agent_rc "$WORK/nope-daemon.plist" "$AGENT")"
assert_eq "a missing agent plist is refused"  1 "$(agent_rc "$DAEMON" "$WORK/nope-agent.plist")"
agent_rc "$WORK/nope-daemon.plist" "$AGENT" >/dev/null
assert_contains "the daemon refusal names the missing path" "$agent_err" "nope-daemon.plist"
agent_rc "$DAEMON" "$WORK/nope-agent.plist" >/dev/null
assert_contains "the agent refusal names the missing path"  "$agent_err" "nope-agent.plist"

# ── assert_nopasswd_sudo ────────────────────────────────────────────────────
# The base ships this drop-in already (measured on a real Cirrus base), so
# the assertion is existence + visudo syntax validity, not an install — the
# same "assert what the base already guarantees" contract as
# install_guest_agent above. A corrupt drop-in can break sudo for every
# account, not just this one, which is why syntax gets its own case distinct
# from plain existence.
echo
echo "family-lib (darwin) — assert_nopasswd_sudo:"
sudoers_err=""
sudoers_rc() {  # <sudoers-file-path>
  local rc=0
  sudoers_err=$( ( export SUDOERS_NOPASSWD_FILE="$1"
                    # shellcheck source=/dev/null
                    source "$LIB"
                    assert_nopasswd_sudo ) 2>&1 ) || rc=$?
  printf '%s' "$rc"
}
VALID_SUDOERS="$WORK/admin-nopasswd"
printf 'admin ALL=(ALL) NOPASSWD: ALL\n' > "$VALID_SUDOERS"
BAD_SUDOERS="$WORK/admin-nopasswd-bad"
printf 'this is not valid sudoers syntax !!!\n' > "$BAD_SUDOERS"
assert_eq "a present, syntactically valid drop-in passes"  0 "$(sudoers_rc "$VALID_SUDOERS")"
assert_eq "a missing drop-in is refused"                   1 "$(sudoers_rc "$WORK/does-not-exist")"
assert_eq "a present but malformed drop-in is refused"     1 "$(sudoers_rc "$BAD_SUDOERS")"
sudoers_rc "$WORK/does-not-exist" >/dev/null
assert_contains "the missing-file refusal names the path"    "$sudoers_err" "does-not-exist"
sudoers_rc "$BAD_SUDOERS" >/dev/null
assert_contains "the malformed-file refusal names visudo"    "$sudoers_err" "visudo"

echo; echo "  $pass passed, $fail failed"; [ "$fail" -eq 0 ]
