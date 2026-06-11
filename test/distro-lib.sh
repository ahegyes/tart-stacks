#!/usr/bin/env bash
# Characterization test for distro-lib.sh _detect_family: os-release ID/ID_LIKE →
# family. Extracts the function from source (tracks it through refactors) and
# exercises it against synthetic os-release files. No framework.
set -uo pipefail
TEST_DIR=$(cd -P "$(dirname "$0")" >/dev/null 2>&1 && pwd); REPO=$(cd -P "$TEST_DIR/.." >/dev/null 2>&1 && pwd)
pass=0 fail=0
ok(){ pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad(){ fail=$((fail+1)); printf '  FAIL %s\n    exp|%s\n    got|%s\n' "$1" "$2" "$3"; }
assert_eq(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "$2" "$3"; fi; }
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
# manifest. Source the whole lib (family comes from the os-release fixture);
# package managers are PATH mocks. apt's per-package loop knows its failures
# directly; dnf's --skip-unavailable is silent, so the lib post-checks rpm -q.
MOCKBIN="$WORK/bin"; mkdir -p "$MOCKBIN"
cat > "$MOCKBIN/apt-get" <<'M'
#!/usr/bin/env bash
[ "${MOCK_APT_FAIL:-}" = "${4:-}" ] && exit 100
exit 0
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
chmod +x "$MOCKBIN/apt-get" "$MOCKBIN/dnf" "$MOCKBIN/rpm"

echo "distro-lib — pkg_install_optional skip recording:"
SKIP="$WORK/skipped-apt"
# shellcheck disable=SC2030  # the subshell-scoped env IS the sandbox
( export PATH="$MOCKBIN:$PATH" OS_RELEASE="$WORK/u" TART_SKIPPED_FILE="$SKIP" MOCK_APT_FAIL="gone-pkg"
  # shellcheck source=/dev/null
  source "$REPO/shared/scripts/distro-lib.sh"
  pkg_install_optional kept-pkg gone-pkg ) >/dev/null 2>&1
assert_eq "apt: only the skipped package is recorded" "gone-pkg" "$(cat "$SKIP" 2>/dev/null)"

SKIP2="$WORK/skipped-dnf"
# shellcheck disable=SC2030,SC2031  # the subshell-scoped env IS the sandbox
( export PATH="$MOCKBIN:$PATH" OS_RELEASE="$WORK/f" TART_SKIPPED_FILE="$SKIP2" MOCK_RPM_MISSING="ghost-pkg"
  # shellcheck source=/dev/null
  source "$REPO/shared/scripts/distro-lib.sh"
  pkg_install_optional present-pkg ghost-pkg ) >/dev/null 2>&1
assert_eq "dnf: the rpm-absent package is recorded" "ghost-pkg" "$(cat "$SKIP2" 2>/dev/null)"

echo; echo "  $pass passed, $fail failed"; [ "$fail" -eq 0 ]
