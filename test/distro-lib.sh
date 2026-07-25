#!/usr/bin/env bash
# Characterization test for distro-lib.sh _detect_family: os-release ID/ID_LIKE →
# family. Extracts the function from source (tracks it through refactors) and
# exercises it against synthetic os-release files. No framework.
set -uo pipefail
TEST_DIR=$(cd -P "$(dirname "$0")" >/dev/null 2>&1 && pwd); REPO=$(cd -P "$TEST_DIR/.." >/dev/null 2>&1 && pwd)
pass=0 fail=0
ok(){ pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  FAIL %s\n         %s\n' "$1" "${2:-}"; }
assert_eq(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "want » $2 « got » $3 «"; fi; }
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
# Extract _detect_family and source it (same technique parsing.sh uses for tart-up fns).
awk 'index($0,"_detect_family() {")==1{p=1} p{print} p&&$0=="}"{exit}' "$REPO/shared/scripts/distro-lib.sh" > "$WORK/fn.sh"
# shellcheck source=/dev/null
source "$WORK/fn.sh"
echo "distro-lib — _detect_family:"
printf 'ID=fedora\n'                 > "$WORK/f"; assert_eq "fedora -> dnf"      dnf "$(OS_RELEASE=$WORK/f _detect_family)"
printf 'ID=ubuntu\nID_LIKE=debian\n' > "$WORK/u"; assert_eq "ubuntu -> apt"      apt "$(OS_RELEASE=$WORK/u _detect_family)"
printf 'ID=debian\n'                 > "$WORK/d"; assert_eq "debian -> apt"      apt "$(OS_RELEASE=$WORK/d _detect_family)"
printf 'ID=rhel\nID_LIKE=fedora\n'   > "$WORK/r"; assert_eq "rhel -> dnf"        dnf "$(OS_RELEASE=$WORK/r _detect_family)"
printf 'ID=arch\n'                   > "$WORK/a"; assert_eq "arch -> empty(rc1)" ""  "$(OS_RELEASE=$WORK/a _detect_family || true)"
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
[ "${MOCK_APT_FAIL:-}" = "${4:-}" ] && exit 100
exit 0
M
cat > "$MOCKBIN/apt-cache" <<'M'
#!/usr/bin/env bash
[ "${MOCK_APT_CACHE_RC:-0}" -eq 0 ] || exit "$MOCK_APT_CACHE_RC"
# `apt-cache policy <pkg>`: a package the archive does not carry reports
# Candidate: (none), which is the only thing that counts as unavailable.
if [ "${MOCK_APT_ABSENT:-}" = "${2:-}" ]; then
  printf '%s:\n  Candidate: (none)\n' "$2"
else
  printf '%s:\n  Candidate: 1.0\n' "$2"
fi
M
cat > "$MOCKBIN/dnf" <<'M'
#!/usr/bin/env bash
exit 0
M
cat > "$MOCKBIN/rpm" <<'M'
#!/usr/bin/env bash
[ "${MOCK_RPM_MISSING:-}" = "${2:-}" ] && exit 1
exit 0
M
chmod +x "$MOCKBIN/apt-get" "$MOCKBIN/apt-cache" "$MOCKBIN/dnf" "$MOCKBIN/rpm"

echo "distro-lib — pkg_install_optional skip recording:"
SKIP="$WORK/skipped-apt"
# shellcheck disable=SC2030  # the subshell-scoped env IS the sandbox
( export PATH="$MOCKBIN:$PATH" OS_RELEASE="$WORK/u" TART_SKIPPED_FILE="$SKIP" MOCK_APT_ABSENT="gone-pkg"
  # shellcheck source=/dev/null
  source "$REPO/shared/scripts/distro-lib.sh"
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
  source "$REPO/shared/scripts/distro-lib.sh"
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
  source "$REPO/shared/scripts/distro-lib.sh"
  pkg_install_optional anypkg ) >/dev/null 2>&1 || qfail_rc=$?
assert_eq "apt: a failing query is not recorded as unavailable" "" "$(cat "$SKIP_QFAIL" 2>/dev/null)"
if [ "$qfail_rc" -ne 0 ]; then
  ok "apt: a failing query surfaces its failure"
else
  bad "apt: a failing query surfaces its failure" "want » nonzero « got » $qfail_rc «"
fi

SKIP2="$WORK/skipped-dnf"
# shellcheck disable=SC2030,SC2031  # the subshell-scoped env IS the sandbox
( export PATH="$MOCKBIN:$PATH" OS_RELEASE="$WORK/f" TART_SKIPPED_FILE="$SKIP2" MOCK_RPM_MISSING="ghost-pkg"
  # shellcheck source=/dev/null
  source "$REPO/shared/scripts/distro-lib.sh"
  pkg_install_optional present-pkg ghost-pkg ) >/dev/null 2>&1
assert_eq "dnf: the rpm-absent package is recorded" "ghost-pkg" "$(cat "$SKIP2" 2>/dev/null)"

echo; echo "  $pass passed, $fail failed"; [ "$fail" -eq 0 ]
