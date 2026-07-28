#!/usr/bin/env bash
# Characterization test for family-lib.sh _detect_family: os-release ID/ID_LIKE →
# family. Extracts the function from source (tracks it through refactors) and
# exercises it against synthetic os-release files. No framework.
set -uo pipefail
TEST_DIR=$(cd -P "$(dirname "$0")" >/dev/null 2>&1 && pwd); REPO=$(cd -P "$TEST_DIR/.." >/dev/null 2>&1 && pwd)
pass=0 fail=0
ok(){ pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  FAIL %s\n         %s\n' "$1" "${2:-}"; }
assert_eq(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "want » $2 « got » $3 «"; fi; }
assert_contains(){ case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "want » $3 « in: $2" ;; esac; }
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
# Extract _detect_family and source it (same technique parsing.sh uses for tart-up fns).
awk 'index($0,"_detect_family() {")==1{p=1} p{print} p&&$0=="}"{exit}' "$REPO/shared/linux/scripts/family-lib.sh" > "$WORK/fn.sh"
# shellcheck source=/dev/null
source "$WORK/fn.sh"
echo "family-lib — _detect_family:"
printf 'ID=fedora\n'                 > "$WORK/f"; assert_eq "fedora -> dnf"      dnf "$(OS_RELEASE=$WORK/f _detect_family)"
printf 'ID=ubuntu\nID_LIKE=debian\n' > "$WORK/u"; assert_eq "ubuntu -> apt"      apt "$(OS_RELEASE=$WORK/u _detect_family)"
printf 'ID=debian\n'                 > "$WORK/d"; assert_eq "debian -> apt"      apt "$(OS_RELEASE=$WORK/d _detect_family)"
printf 'ID=arch\n'                   > "$WORK/a"; assert_eq "arch -> empty(rc1)" ""  "$(OS_RELEASE=$WORK/a _detect_family || true)"
# An ID_LIKE=fedora rebuild must NOT reach the dnf branch: it uses `rpm -E
# %fedora` for a Fedora-release COPR URL, `copr enable` and `development-tools`,
# so it would pass the gate and fail partway through a build.
printf 'ID=rhel\nID_LIKE=fedora\n'   > "$WORK/r"; assert_eq "rhel -> unsupported(rc1)"  "" "$(OS_RELEASE=$WORK/r _detect_family || true)"
printf 'ID=rocky\nID_LIKE="rhel centos fedora"\n' > "$WORK/ro"; assert_eq "rocky -> unsupported(rc1)" "" "$(OS_RELEASE=$WORK/ro _detect_family || true)"
# The apt side keeps ID_LIKE on purpose — its branch is portable apt/dpkg only.
printf 'ID=linuxmint\nID_LIKE=ubuntu\n' > "$WORK/lm"; assert_eq "an ubuntu derivative -> apt" apt "$(OS_RELEASE=$WORK/lm _detect_family)"
# ── pkg_install_optional: skip recording ────────────────────────────────────
# Skipped optional packages land in $TART_SKIPPED_FILE for the provenance
# manifest, which describes the image — so only a package the family genuinely
# lacks may be recorded. Source the whole lib (family comes from the os-release
# fixture); package managers are PATH mocks. apt resolves the candidate first,
# so an install failure is a broken build rather than a skip; dnf's
# --skip-unavailable is silent, so the lib post-checks rpm -q.
MOCKBIN="$WORK/bin"; mkdir -p "$MOCKBIN"
cat > "$MOCKBIN/apt-get" <<'M'
#!/usr/bin/env bash
[ -n "${MOCK_APT_LOG:-}" ] && printf '%s\n' "$*" >> "$MOCK_APT_LOG"
# Guarded on being SET, not just on matching: `apt-get install -y <file>` has no
# $4, so an unset knob would compare empty to empty and fail every such call.
[ -n "${MOCK_APT_FAIL:-}" ] && [ "${MOCK_APT_FAIL}" = "${4:-}" ] && exit 100
exit 0
M
cat > "$MOCKBIN/apt-cache" <<'M'
#!/usr/bin/env bash
[ "${MOCK_APT_CACHE_RC:-0}" -eq 0 ] || exit "$MOCK_APT_CACHE_RC"
case "$1" in
  policy)
    # `Candidate: (none)` is what a package the archive does not carry reports —
    # and equally what a PURE VIRTUAL one reports, which is why the lib consults
    # showpkg next rather than treating it as unavailable on its own.
    if [ "${MOCK_APT_ABSENT:-}" = "${2:-}" ] || [ "${MOCK_APT_VIRTUAL:-}" = "${2:-}" ]; then
      printf '%s:\n  Candidate: (none)\n' "$2"
    else
      printf '%s:\n  Candidate: 1.0\n' "$2"
    fi ;;
  showpkg)
    [ "${MOCK_APT_SHOWPKG_RC:-0}" -eq 0 ] || exit "$MOCK_APT_SHOWPKG_RC"
    # Real apt-cache prints nothing at all for a name it has never heard of, and
    # a populated `Reverse Provides:` block for a virtual one.
    if [ "${MOCK_APT_VIRTUAL:-}" = "${2:-}" ]; then
      printf 'Package: %s\nVersions:\n\nReverse Depends:\nReverse Provides:\nprovider-pkg 1.0\n' "$2"
    fi ;;
esac
exit 0
M
cat > "$MOCKBIN/dnf" <<'M'
#!/usr/bin/env bash
# The release-upgrade cases assert on WHICH commands were issued, because that
# path never returns success to assert on. Logging is opt-in via MOCK_DNF_LOG so
# the older cases, which only need a compliant exit status, are untouched.
[ -n "${MOCK_DNF_LOG:-}" ] && printf '%s\n' "$*" >> "$MOCK_DNF_LOG"
exit 0
M
cat > "$MOCKBIN/sleep" <<'M'
#!/usr/bin/env bash
# pkg_release_upgrade blocks here until the guest goes down. A mocked guest never
# does, so collapse the wait and record that it happened — including its argument,
# which the cases use to prove the wait is finite.
[ -n "${MOCK_DNF_LOG:-}" ] && printf 'slept %s\n' "$*" >> "$MOCK_DNF_LOG"
exit 0
M
cat > "$MOCKBIN/rpm" <<'M'
#!/usr/bin/env bash
# `rpm -E %fedora` is how the lib reads the guest's own release. Unset is a mock
# gap rather than a default, so a case that forgets it fails loudly instead of
# silently measuring release 0.
if [ "${1:-}" = "-E" ]; then printf '%s\n' "${MOCK_FEDORA_VER:?rpm mock: MOCK_FEDORA_VER unset}"; exit 0; fi
# `rpm -q <name>` and `rpm -q --whatprovides <name>` diverge for a package dnf
# resolved through a compat Provides: MOCK_RPM_RENAMED is absent under its own
# name but provided by something else, MOCK_RPM_MISSING is absent either way.
if [ "${2:-}" = "--whatprovides" ]; then
  [ "${MOCK_RPM_MISSING:-}" = "${3:-}" ] && exit 1
else
  [ "${MOCK_RPM_MISSING:-}" = "${2:-}" ] && exit 1
  [ "${MOCK_RPM_RENAMED:-}" = "${2:-}" ] && exit 1
fi
exit 0
M
cat > "$MOCKBIN/getenforce" <<'M'
#!/usr/bin/env bash
printf '%s\n' "${MOCK_SELINUX-Enforcing}"
exit "${MOCK_GETENFORCE_RC:-0}"
M
cat > "$MOCKBIN/aa-status" <<'M'
#!/usr/bin/env bash
printf '%s\n' "${MOCK_AA_ENFORCED-7}"
exit "${MOCK_AA_STATUS_RC:-0}"
M
chmod +x "$MOCKBIN/apt-get" "$MOCKBIN/apt-cache" "$MOCKBIN/dnf" "$MOCKBIN/rpm" \
  "$MOCKBIN/getenforce" "$MOCKBIN/aa-status" "$MOCKBIN/sleep"

echo "family-lib — pkg_install_optional skip recording:"
SKIP="$WORK/skipped-apt"
# shellcheck disable=SC2030  # the subshell-scoped env IS the sandbox
( export PATH="$MOCKBIN:$PATH" OS_RELEASE="$WORK/u" TART_SKIPPED_FILE="$SKIP" MOCK_APT_ABSENT="gone-pkg"
  # shellcheck source=/dev/null
  source "$REPO/shared/linux/scripts/family-lib.sh"
  pkg_install_optional kept-pkg gone-pkg ) >/dev/null 2>&1
assert_eq "apt: only the absent package is recorded" "gone-pkg" "$(cat "$SKIP" 2>/dev/null)"

# An install that FAILS on a package the archive does carry is a broken build,
# not a droppable capability: it must not be recorded as unavailable, because
# the manifest would then claim the archive lacks a package it ships.
SKIP_FAIL="$WORK/skipped-apt-fail"
apt_fail_rc=0
# shellcheck disable=SC2030,SC2031  # the subshell-scoped env IS the sandbox
( export PATH="$MOCKBIN:$PATH" OS_RELEASE="$WORK/u" TART_SKIPPED_FILE="$SKIP_FAIL" MOCK_APT_FAIL="broken-pkg"
  # shellcheck source=/dev/null
  source "$REPO/shared/linux/scripts/family-lib.sh"
  pkg_install_optional broken-pkg ) >/dev/null 2>&1 || apt_fail_rc=$?
assert_eq "apt: a failing install is not recorded as unavailable" "" "$(cat "$SKIP_FAIL" 2>/dev/null)"
if [ "$apt_fail_rc" -ne 0 ]; then
  ok "apt: a failing install surfaces its failure"
else
  bad "apt: a failing install surfaces its failure" "want » nonzero « got » $apt_fail_rc «"
fi


# A FAILING apt-cache says nothing about availability. Recording its empty
# output as "unavailable" would put the same lie one layer up from the apt-get
# failure this path exists to stop trusting.
SKIP_QFAIL="$WORK/skipped-queryfail"
qfail_rc=0
# shellcheck disable=SC2030,SC2031  # the subshell-scoped env IS the sandbox
( export PATH="$MOCKBIN:$PATH" OS_RELEASE="$WORK/u" TART_SKIPPED_FILE="$SKIP_QFAIL" MOCK_APT_CACHE_RC=100
  # shellcheck source=/dev/null
  source "$REPO/shared/linux/scripts/family-lib.sh"
  pkg_install_optional anypkg ) >/dev/null 2>&1 || qfail_rc=$?
assert_eq "apt: a failing query is not recorded as unavailable" "" "$(cat "$SKIP_QFAIL" 2>/dev/null)"
if [ "$qfail_rc" -ne 0 ]; then
  ok "apt: a failing query surfaces its failure"
else
  bad "apt: a failing query surfaces its failure" "want » nonzero « got » $qfail_rc «"
fi

# `Candidate: (none)` also describes a PURE VIRTUAL package — no version of its
# own, but providers apt-get install resolves. Verified on a live ubuntu guest
# against a synthetic local repo: a virtual with one provider installs it, so
# recording that name as unavailable drops a capability the archive carries.
SKIP_VIRT="$WORK/skipped-virtual"
APT_LOG="$WORK/apt-calls"; : > "$APT_LOG"
# shellcheck disable=SC2030,SC2031  # the subshell-scoped env IS the sandbox
( export PATH="$MOCKBIN:$PATH" OS_RELEASE="$WORK/u" TART_SKIPPED_FILE="$SKIP_VIRT" \
         MOCK_APT_VIRTUAL="virt-pkg" MOCK_APT_LOG="$APT_LOG"
  # shellcheck source=/dev/null
  source "$REPO/shared/linux/scripts/family-lib.sh"
  pkg_install_optional virt-pkg ) >/dev/null 2>&1
assert_eq "apt: a virtual package with a provider is not recorded" "" "$(cat "$SKIP_VIRT" 2>/dev/null)"
assert_contains "apt: a virtual package is still handed to apt-get" "$(cat "$APT_LOG")" "install -y --no-install-recommends virt-pkg"

# A FAILING provider query says nothing about availability either — same rule as
# the policy query one layer up.
SKIP_SFAIL="$WORK/skipped-showpkgfail"
sfail_rc=0
# shellcheck disable=SC2030,SC2031  # the subshell-scoped env IS the sandbox
( export PATH="$MOCKBIN:$PATH" OS_RELEASE="$WORK/u" TART_SKIPPED_FILE="$SKIP_SFAIL" \
         MOCK_APT_ABSENT="q-pkg" MOCK_APT_SHOWPKG_RC=100
  # shellcheck source=/dev/null
  source "$REPO/shared/linux/scripts/family-lib.sh"
  pkg_install_optional q-pkg ) >/dev/null 2>&1 || sfail_rc=$?
assert_eq "apt: a failing provider query is not recorded as unavailable" "" "$(cat "$SKIP_SFAIL" 2>/dev/null)"
if [ "$sfail_rc" -ne 0 ]; then
  ok "apt: a failing provider query surfaces its failure"
else
  bad "apt: a failing provider query surfaces its failure" "want » nonzero « got » $sfail_rc «"
fi

SKIP2="$WORK/skipped-dnf"
# shellcheck disable=SC2030,SC2031  # the subshell-scoped env IS the sandbox
( export PATH="$MOCKBIN:$PATH" OS_RELEASE="$WORK/f" TART_SKIPPED_FILE="$SKIP2" MOCK_RPM_MISSING="ghost-pkg"
  # shellcheck source=/dev/null
  source "$REPO/shared/linux/scripts/family-lib.sh"
  pkg_install_optional present-pkg ghost-pkg ) >/dev/null 2>&1
assert_eq "dnf: the rpm-absent package is recorded" "ghost-pkg" "$(cat "$SKIP2" 2>/dev/null)"

# dnf resolves a renamed package through a compat Provides, installing the
# capability under a different rpm name. Verified on a live fedora-php clone:
# `rpm -q libmemcached-devel` fails while `rpm -q --whatprovides` names
# libmemcached-awesome-devel — so an exact-name post-check records a package the
# image is carrying, in the one file built to answer "what is this image?".
SKIP_REN="$WORK/skipped-renamed"
# shellcheck disable=SC2030,SC2031  # the subshell-scoped env IS the sandbox
( export PATH="$MOCKBIN:$PATH" OS_RELEASE="$WORK/f" TART_SKIPPED_FILE="$SKIP_REN" MOCK_RPM_RENAMED="oldname-devel"
  # shellcheck source=/dev/null
  source "$REPO/shared/linux/scripts/family-lib.sh"
  pkg_install_optional oldname-devel ) >/dev/null 2>&1
assert_eq "dnf: a package present under a Provides alias is not recorded" "" "$(cat "$SKIP_REN" 2>/dev/null)"

# ── assert_integrity_enforced ────────────────────────────────────────────────
# Its whole job is to fail a build, so an untested one can only be discovered by
# shipping an image whose inherited MAC posture had silently regressed.
echo "family-lib — assert_integrity_enforced:"
mac_rc() { # <os-release-fixture> [KEY=VALUE…] — exit status of assert_integrity_enforced
  local fixture="$1"; shift
  local rc=0
  # env, not export: the mock knobs arrive as KEY=VALUE words, which `export`
  # would have to be handed unquoted. A child bash keeps the family detection
  # (and family-lib's own hard exit) out of this shell.
  # shellcheck disable=SC2031  # the child process env IS the sandbox
  # shellcheck disable=SC2016  # $1 is the child shell's argument, not this one's
  env PATH="$MOCKBIN:$PATH" OS_RELEASE="$fixture" "$@" \
    bash -c '. "$1"; assert_integrity_enforced' _ "$REPO/shared/linux/scripts/family-lib.sh" \
    >/dev/null 2>&1 || rc=$?
  printf '%s' "$rc"
}
assert_eq "dnf: SELinux Enforcing passes"          0 "$(mac_rc "$WORK/f")"
assert_eq "dnf: SELinux Permissive fails"          1 "$(mac_rc "$WORK/f" MOCK_SELINUX=Permissive)"
assert_eq "dnf: SELinux Disabled fails"            1 "$(mac_rc "$WORK/f" MOCK_SELINUX=Disabled)"
# A missing getenforce leaves the posture unknown, which must not read as fine.
assert_eq "dnf: an unavailable getenforce fails"   1 "$(mac_rc "$WORK/f" MOCK_SELINUX= MOCK_GETENFORCE_RC=127)"
assert_eq "apt: enforce-mode profiles pass"        0 "$(mac_rc "$WORK/u")"
assert_eq "apt: zero enforce-mode profiles fail"   1 "$(mac_rc "$WORK/u" MOCK_AA_ENFORCED=0)"
# aa-status exits nonzero when AppArmor is absent; its output is then not a count.
assert_eq "apt: an unavailable aa-status fails"    1 "$(mac_rc "$WORK/u" MOCK_AA_ENFORCED= MOCK_AA_STATUS_RC=1)"
assert_eq "apt: non-numeric profile output fails"  1 "$(mac_rc "$WORK/u" MOCK_AA_ENFORCED=unconfined)"
# A family with no branch here must fail, not fall off the end of the case: the
# README's "add a new package family" checklist enumerates the package functions,
# so the first third family would otherwise ship images whose MAC gate is a no-op.
# The family is overridden AFTER sourcing, since the lib hard-exits on one it
# cannot detect — which is exactly the shape a half-added third family takes.
unknown_family_rc() {
  local rc=0
  # shellcheck disable=SC2016  # $1 is the child shell's argument, not this one's
  # shellcheck disable=SC2031  # PATH is per-child on purpose; the mocks are the sandbox
  env PATH="$MOCKBIN:$PATH" OS_RELEASE="$WORK/f" \
    bash -c '. "$1"; _TART_FAMILY=zypper; assert_integrity_enforced' _ \
      "$REPO/shared/linux/scripts/family-lib.sh" >/dev/null 2>&1 || rc=$?
  printf '%s' "$rc"
}
assert_eq "an unknown family fails rather than passing" 1 "$(unknown_family_rc)"

# ── pkg_release_upgrade ──────────────────────────────────────────────────────
# The dnf upgrade path never returns 0 by design: it ends by blocking until the
# guest goes down, so any return at all means the reboot did not happen. These
# cases therefore measure the commands ISSUED; the status is asserted separately.
# The target is injected rather than read from the shipped pin, so raising
# FEDORA_TARGET_RELEASE never rewrites these expectations.
echo
echo "family-lib — pkg_release_upgrade:"
UPG_LOG="$WORK/dnf-log"; UPG_ERR=""; UPG_RC=0
# upgrade_run <os-release-fixture> <guest-release> <target> — leaves the status in
# $UPG_RC, the issued commands in $UPG_LOG, and combined output in $UPG_ERR.
# Called directly and never inside $( ): a command substitution runs the function
# in a subshell, where every global it sets is discarded and the message
# assertions would silently compare against an empty string.
upgrade_run() {
  UPG_RC=0
  : > "$UPG_LOG"
  # shellcheck disable=SC2030,SC2031  # the subshell-scoped env IS the sandbox
  UPG_ERR=$( ( export PATH="$MOCKBIN:$PATH" OS_RELEASE="$1" MOCK_FEDORA_VER="$2" \
                 FEDORA_TARGET_RELEASE="$3" MOCK_DNF_LOG="$UPG_LOG"
               # shellcheck source=/dev/null
               source "$REPO/shared/linux/scripts/family-lib.sh"
               pkg_release_upgrade ) 2>&1 ) || UPG_RC=$?
}

# apt bases are current and tracked by their publisher — the function must not
# reach for a package manager at all there.
upgrade_run "$WORK/u" 42 44
assert_eq "apt: no-op"                       0  "$UPG_RC"
assert_eq "apt: issues no package commands"  "" "$(cat "$UPG_LOG")"

# The upgrade proper. Ordering is the point: downloading after asking for the
# reboot would stage nothing.
upgrade_run "$WORK/f" 42 44
assert_eq "dnf: download precedes the reboot request" \
  "$(printf 'system-upgrade download --releasever=44 -y\n-y offline reboot')" \
  "$(grep -v '^slept ' "$UPG_LOG")"
assert_eq "dnf: refuses if it ever returns"  1 "$UPG_RC"
assert_contains "dnf: says why returning is a failure" "$UPG_ERR" "did not go down"
# The wait must be finite. `sleep infinity` would hang a build forever when the
# reboot never comes, instead of failing it after a bounded window.
upg_slept=$(grep '^slept ' "$UPG_LOG" | awk '{print $2}')
case "$upg_slept" in
  ''|*[!0-9]*) bad "dnf: the post-reboot wait is bounded" "slept » ${upg_slept:-nothing} « — not a finite number of seconds" ;;
  *)           ok  "dnf: the post-reboot wait is bounded" ;;
esac

# -ge, not -eq: the day the upstream base is republished at or beyond the target,
# this has to fall silent by itself rather than downgrade or need deleting.
upgrade_run "$WORK/f" 44 44
assert_eq "dnf: already at the target is a no-op"   0  "$UPG_RC"
assert_eq "dnf: ...and issues nothing"              "" "$(cat "$UPG_LOG")"
upgrade_run "$WORK/f" 45 44
assert_eq "dnf: a base ahead of the target no-ops"  0  "$UPG_RC"
assert_eq "dnf: ...and issues nothing"              "" "$(cat "$UPG_LOG")"

# dnf upgrades at most two releases at once. A wider gap must be refused BEFORE
# anything is downloaded — attempting it wastes the transfer and fails obscurely.
upgrade_run "$WORK/f" 42 45
assert_eq "dnf: a 3-release jump is refused"        1  "$UPG_RC"
assert_eq "dnf: ...before downloading anything"     "" "$(cat "$UPG_LOG")"
assert_contains "dnf: the refusal names the reachable target" "$UPG_ERR" "at most 44"
# The boundary itself, measured by what was issued rather than by status: a
# 2-release and a 3-release gap both end nonzero, so only the log tells them apart.
upgrade_run "$WORK/f" 42 44
assert_contains "dnf: exactly two releases proceeds" "$(cat "$UPG_LOG")" "--releasever=44"

# A family added without a branch here would silently inherit whatever release its
# base shipped at — the exact failure this function exists to end, so it fails closed.
release_unknown_family_rc() {
  local rc=0
  # shellcheck disable=SC2016  # $1 is the child shell's argument, not this one's
  # shellcheck disable=SC2031  # PATH is per-child on purpose; the mocks are the sandbox
  env PATH="$MOCKBIN:$PATH" OS_RELEASE="$WORK/f" \
    bash -c '. "$1"; _TART_FAMILY=zypper; pkg_release_upgrade' _ \
      "$REPO/shared/linux/scripts/family-lib.sh" >/dev/null 2>&1 || rc=$?
  printf '%s' "$rc"
}
assert_eq "an unknown family is refused, not skipped" 1 "$(release_unknown_family_rc)"

# ── assert_release_supported ─────────────────────────────────────────────────
# The gate that stops a hand-maintained release pin going stale in silence.
echo
echo "family-lib — assert_release_supported:"
printf 'ID=fedora\nPRETTY_NAME="Fedora Linux 42 (Cloud Edition)"\nSUPPORT_END=2026-05-13\n' > "$WORK/eol"
printf 'ID=fedora\nPRETTY_NAME="Fedora Linux 44 (Cloud Edition)"\nSUPPORT_END=2027-05-19\n' > "$WORK/live"
REL_ERR=""
rel_rc() {  # <os-release-fixture> <today>
  local rc=0
  # shellcheck disable=SC2030,SC2031  # the subshell-scoped env IS the sandbox
  REL_ERR=$( ( export PATH="$MOCKBIN:$PATH" OS_RELEASE="$1" TART_TODAY="$2"
               # shellcheck source=/dev/null
               source "$REPO/shared/linux/scripts/family-lib.sh"
               assert_release_supported ) 2>&1 ) || rc=$?
  printf '%s' "$rc"
}
assert_eq "a release past its support end fails"  1 "$(rel_rc "$WORK/eol"  2026-07-27)"
assert_eq "a supported release passes"            0 "$(rel_rc "$WORK/live" 2026-07-27)"
# The window closes AFTER that date, so the day itself is still supported —
# an off-by-one here would fail a build on the last good day.
assert_eq "the support-end date itself passes"    0 "$(rel_rc "$WORK/eol"  2026-05-13)"
assert_eq "the day after it fails"                1 "$(rel_rc "$WORK/eol"  2026-05-14)"
# The apt family publishes no SUPPORT_END. Absence says nothing about support, so
# guessing would fail every Debian and Ubuntu build on a field they never set.
assert_eq "no SUPPORT_END is a skip, not a failure" 0 "$(rel_rc "$WORK/u" 2026-07-27)"
# The refusal has to carry both halves of the fix: which release died when, and
# the knob that moves it.
rel_rc "$WORK/eol" 2026-07-27 >/dev/null
assert_contains "the refusal names the release"      "$REL_ERR" "Fedora Linux 42"
assert_contains "the refusal names the end date"     "$REL_ERR" "2026-05-13"
assert_contains "the refusal names today"            "$REL_ERR" "2026-07-27"
assert_contains "the refusal names the knob to turn" "$REL_ERR" "FEDORA_TARGET_RELEASE"

# ── install_guest_agent ──────────────────────────────────────────────────────
# The agent executes what the host asks of it as a passwordless-sudo account, so
# the cases that matter most are the ones that must REFUSE: a hash that does not
# match, and a package the checksums file does not mention at all. Both have to
# fail before anything reaches the package manager.
echo
echo "family-lib — install_guest_agent:"
cat > "$MOCKBIN/curl" <<'M'
#!/usr/bin/env bash
[ "${MOCK_CURL_FAIL:-0}" = "1" ] && exit 22
dest=""
while [ $# -gt 0 ]; do
  case "$1" in -o) dest="$2"; shift 2 ;; *) shift ;; esac
done
# The checksums fetch and the package fetch are told apart by their destination,
# which is what the lib actually controls.
case "$dest" in
  *checksums) printf '%s  %s\n' "${MOCK_SUM_VALUE:-goodhash}" "${MOCK_SUM_NAME:-unset}" > "$dest" ;;
  *)          printf 'not-a-real-package\n' > "$dest" ;;
esac
exit 0
M
cat > "$MOCKBIN/sha256sum" <<'M'
#!/usr/bin/env bash
printf '%s  %s\n' "${MOCK_ACTUAL_SHA:-goodhash}" "${1:-}"
M
cat > "$MOCKBIN/uname" <<'M'
#!/usr/bin/env bash
[ "${1:-}" = "-m" ] && { printf '%s\n' "${MOCK_UNAME_M:-aarch64}"; exit 0; }
printf 'Linux\n'
M
cat > "$MOCKBIN/systemctl" <<'M'
#!/usr/bin/env bash
[ -n "${MOCK_DNF_LOG:-}" ] && printf 'systemctl %s\n' "$*" >> "$MOCK_DNF_LOG"
exit 0
M
chmod +x "$MOCKBIN/curl" "$MOCKBIN/sha256sum" "$MOCKBIN/uname" "$MOCKBIN/systemctl"

AG_LOG="$WORK/agent-log"; AG_ERR=""; AG_RC=0
# agent_run <os-release-fixture> <version> [VAR=VAL ...] — leaves status in $AG_RC,
# package-manager and systemctl calls in $AG_LOG, combined output in $AG_ERR.
# Called directly, never in $( ): a subshell would discard all three.
agent_run() {
  local fixture="$1" ver="$2"; shift 2
  AG_RC=0; : > "$AG_LOG"
  # Both package managers log to the same file here: which one ran is the thing
  # under test, so they must be visible in one place and in order.
  # shellcheck disable=SC2030,SC2031  # the subshell-scoped env IS the sandbox
  # shellcheck disable=SC2163  # "$@" carries literal NAME=VALUE pairs, which is
  # exactly what export takes as operands — not an indirect variable name
  AG_ERR=$( ( export PATH="$MOCKBIN:$PATH" OS_RELEASE="$fixture" \
                TART_GUEST_AGENT_VERSION="$ver" \
                MOCK_DNF_LOG="$AG_LOG" MOCK_APT_LOG="$AG_LOG" "$@"
              # shellcheck source=/dev/null
              source "$REPO/shared/linux/scripts/family-lib.sh"
              install_guest_agent ) 2>&1 ) || AG_RC=$?
}

# The happy paths: right package name per family, then install, then the unit is
# reloaded and enabled --now (a clone's first boot needs it enabled, and the
# assertions in 00-base.sh read the running state).
agent_run "$WORK/f" 0.11.0 MOCK_SUM_NAME=tart-guest-agent_0.11.0_linux_arm64.rpm
assert_eq       "dnf: succeeds"                    0 "$AG_RC"
assert_contains "dnf: installs the .rpm"           "$(cat "$AG_LOG")" "tart-guest-agent_0.11.0_linux_arm64.rpm"
assert_contains "dnf: reloads units"               "$(cat "$AG_LOG")" "systemctl daemon-reload"
assert_contains "dnf: enables it now"              "$(cat "$AG_LOG")" "enable --now tart-guest-agent.service"

agent_run "$WORK/u" 0.11.0 MOCK_SUM_NAME=tart-guest-agent_0.11.0_linux_arm64.deb
assert_eq       "apt: succeeds"                    0 "$AG_RC"
assert_contains "apt: installs the .deb"           "$(cat "$AG_LOG")" "tart-guest-agent_0.11.0_linux_arm64.deb"

# Architecture comes from the guest, not from an assumption about Apple silicon.
agent_run "$WORK/f" 0.11.0 MOCK_UNAME_M=x86_64 MOCK_SUM_NAME=tart-guest-agent_0.11.0_linux_amd64.rpm
assert_contains "x86_64 maps to the amd64 build"   "$(cat "$AG_LOG")" "linux_amd64.rpm"
agent_run "$WORK/f" 0.11.0 MOCK_UNAME_M=riscv64
assert_eq       "an unknown arch is refused"       1  "$AG_RC"
assert_eq       "...and installs nothing"          "" "$(cat "$AG_LOG")"

# THE case. A package whose hash does not match must never reach the installer.
agent_run "$WORK/f" 0.11.0 MOCK_SUM_NAME=tart-guest-agent_0.11.0_linux_arm64.rpm MOCK_ACTUAL_SHA=tampered
assert_eq       "a sha256 mismatch is refused"     1  "$AG_RC"
assert_eq       "...before installing anything"    "" "$(cat "$AG_LOG")"
assert_contains "...and says so"                   "$AG_ERR" "sha256 mismatch"

# A checksums file that does not list the package at all is not a pass — without
# this branch the expected hash is empty and any download would satisfy it.
agent_run "$WORK/f" 0.11.0 MOCK_SUM_NAME=some-other-artifact.rpm
assert_eq       "an unlisted package is refused"   1  "$AG_RC"
assert_eq       "...before installing anything"    "" "$(cat "$AG_LOG")"
assert_contains "...and says it is unverifiable"   "$AG_ERR" "unverifiable"

agent_run "$WORK/f" 0.11.0 MOCK_CURL_FAIL=1
assert_eq       "a failed download is refused"     1  "$AG_RC"
assert_eq       "...and installs nothing"          "" "$(cat "$AG_LOG")"
# Asserted on the wording, not just the status: without the download check a failed
# fetch still refuses, but by falling through to the empty-checksum branch and
# reporting an unverifiable package — which sends the reader hunting a supply-chain
# problem when the real one was the network.
assert_contains "...and blames the download"       "$AG_ERR" "could not download"

# Same fail-closed rule as the release upgrade: a family with no mapping must not
# quietly keep whatever agent its base shipped.
agent_unknown_family_rc() {
  local rc=0
  # shellcheck disable=SC2016,SC2031
  env PATH="$MOCKBIN:$PATH" OS_RELEASE="$WORK/f" \
    bash -c '. "$1"; _TART_FAMILY=zypper; install_guest_agent' _ \
      "$REPO/shared/linux/scripts/family-lib.sh" >/dev/null 2>&1 || rc=$?
  printf '%s' "$rc"
}
assert_eq "an unknown family is refused, not skipped" 1 "$(agent_unknown_family_rc)"

echo; echo "  $pass passed, $fail failed"; [ "$fail" -eq 0 ]
