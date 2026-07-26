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
assert_contains(){ case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "want » $3 « in: $2" ;; esac; }
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
# Extract _detect_family and source it (same technique parsing.sh uses for tart-up fns).
awk 'index($0,"_detect_family() {")==1{p=1} p{print} p&&$0=="}"{exit}' "$REPO/shared/scripts/distro-lib.sh" > "$WORK/fn.sh"
# shellcheck source=/dev/null
source "$WORK/fn.sh"
echo "distro-lib — _detect_family:"
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
[ "${MOCK_APT_FAIL:-}" = "${4:-}" ] && exit 100
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
exit 0
M
cat > "$MOCKBIN/rpm" <<'M'
#!/usr/bin/env bash
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
  "$MOCKBIN/getenforce" "$MOCKBIN/aa-status"

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
  source "$REPO/shared/scripts/distro-lib.sh"
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
  source "$REPO/shared/scripts/distro-lib.sh"
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
  source "$REPO/shared/scripts/distro-lib.sh"
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
  source "$REPO/shared/scripts/distro-lib.sh"
  pkg_install_optional oldname-devel ) >/dev/null 2>&1
assert_eq "dnf: a package present under a Provides alias is not recorded" "" "$(cat "$SKIP_REN" 2>/dev/null)"

# ── assert_mac_enforcing ─────────────────────────────────────────────────────
# Its whole job is to fail a build, so an untested one can only be discovered by
# shipping an image whose inherited MAC posture had silently regressed.
echo "distro-lib — assert_mac_enforcing:"
mac_rc() { # <os-release-fixture> [KEY=VALUE…] — exit status of assert_mac_enforcing
  local fixture="$1"; shift
  local rc=0
  # env, not export: the mock knobs arrive as KEY=VALUE words, which `export`
  # would have to be handed unquoted. A child bash keeps the family detection
  # (and distro-lib's own hard exit) out of this shell.
  # shellcheck disable=SC2031  # the child process env IS the sandbox
  # shellcheck disable=SC2016  # $1 is the child shell's argument, not this one's
  env PATH="$MOCKBIN:$PATH" OS_RELEASE="$fixture" "$@" \
    bash -c '. "$1"; assert_mac_enforcing' _ "$REPO/shared/scripts/distro-lib.sh" \
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
    bash -c '. "$1"; _DISTRO_FAMILY=zypper; assert_mac_enforcing' _ \
      "$REPO/shared/scripts/distro-lib.sh" >/dev/null 2>&1 || rc=$?
  printf '%s' "$rc"
}
assert_eq "an unknown family fails rather than passing" 1 "$(unknown_family_rc)"

echo; echo "  $pass passed, $fail failed"; [ "$fail" -eq 0 ]
