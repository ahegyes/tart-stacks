#!/usr/bin/env bash
# Characterization test for gui-lib.sh: the DE × family selectors gui.sh keys
# off. Sources distro-lib with a synthetic os-release (family seam), then
# gui-lib on top — same technique as test/distro-lib.sh. No framework.
set -uo pipefail
TEST_DIR=$(cd -P "$(dirname "$0")" >/dev/null 2>&1 && pwd); REPO=$(cd -P "$TEST_DIR/.." >/dev/null 2>&1 && pwd)
pass=0 fail=0
ok(){ pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad(){ fail=$((fail+1)); printf '  FAIL %s\n    exp|%s\n    got|%s\n' "$1" "$2" "$3"; }
assert_eq(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "$2" "$3"; fi; }
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
printf 'ID=fedora\n' > "$WORK/os-dnf"
printf 'ID=debian\n' > "$WORK/os-apt"

# with_family <dnf|apt> <cmd…> — run a selector under that family's libs.
# Subshell per call: distro-lib exits the sourcing shell on a bad os-release,
# and _DISTRO_FAMILY must not leak between cases.
with_family() {
  local fam="$1"; shift
  ( OS_RELEASE="$WORK/os-$fam" source "$REPO/shared/scripts/distro-lib.sh"
    # shellcheck source=/dev/null
    source "$REPO/shared/scripts/gui-lib.sh"
    "$@" ) 2>/dev/null
}

echo "gui-lib — every shared/desktops DE resolves on both families:"
while IFS= read -r de; do
  for fam in dnf apt; do
    pkgs="$(with_family "$fam" gui_packages "$de")"
    if [ -n "$pkgs" ]; then ok "$fam/$de packages non-empty"; else bad "$fam/$de packages non-empty" "packages" "(empty)"; fi
    dm="$(with_family "$fam" gui_dm_unit "$de")"
    case "$dm" in *.service) ok "$fam/$de dm unit is a unit name ($dm)" ;; *) bad "$fam/$de dm unit is a unit name" "*.service" "$dm" ;; esac
  done
  sess="$(with_family dnf gui_session_candidates "$de")"
  if [ -n "$sess" ]; then ok "$de session candidates non-empty"; else bad "$de session candidates non-empty" "candidates" "(empty)"; fi
done < <(grep -vE '^[[:space:]]*(#|$)' "$REPO/shared/desktops")

echo "gui-lib — family-keyed VNC machinery:"
assert_eq "dnf session starter" "/usr/libexec/vncsession-start"      "$(with_family dnf gui_vncsession_start)"
assert_eq "apt session starter" "/usr/libexec/tigervncsession-start" "$(with_family apt gui_vncsession_start)"
assert_eq "dnf pidfile"         "/run/vncsession-:1.pid"             "$(with_family dnf gui_vncsession_pidfile)"
assert_eq "apt pidfile"         "/run/tigervncsession-:1.pid"        "$(with_family apt gui_vncsession_pidfile)"

echo "gui-lib — gui_require_de gate:"
with_family dnf gui_require_de kde; rc=$?
assert_eq "kde accepted" 0 "$rc"
with_family dnf gui_require_de cinnamon; rc=$?
if [ "$rc" -ne 0 ]; then ok "unknown de hard-fails"; else bad "unknown de hard-fails" "rc!=0" "rc=0"; fi

# The lib's supported set and shared/desktops must not drift apart: the
# Makefile validates against the file, the lib is the in-VM backstop.
echo "gui-lib — shared/desktops ↔ gui_require_de lockstep:"
while IFS= read -r de; do
  with_family dnf gui_require_de "$de"; rc=$?
  assert_eq "desktops-file token '$de' accepted by lib" 0 "$rc"
done < <(grep -vE '^[[:space:]]*(#|$)' "$REPO/shared/desktops")

echo; echo "  $pass passed, $fail failed"; [ "$fail" -eq 0 ]
