#!/usr/bin/env bash
# Characterization test for gui-lib.sh: the DE × family selectors gui.sh keys
# off. Sources distro-lib with a synthetic os-release (family seam), then
# gui-lib on top — same technique as test/distro-lib.sh. No framework.
set -uo pipefail
TEST_DIR=$(cd -P "$(dirname "$0")" >/dev/null 2>&1 && pwd); REPO=$(cd -P "$TEST_DIR/.." >/dev/null 2>&1 && pwd)
pass=0 fail=0
ok(){ pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  FAIL %s\n         %s\n' "$1" "${2:-}"; }
assert_eq(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "want » $2 « got » $3 «"; fi; }
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
    if [ -n "$pkgs" ]; then ok "$fam/$de packages non-empty"; else bad "$fam/$de packages non-empty" "want » packages « got » (empty) «"; fi
    dm="$(with_family "$fam" gui_dm_unit "$de")"
    case "$dm" in *.service) ok "$fam/$de dm unit is a unit name ($dm)" ;; *) bad "$fam/$de dm unit is a unit name" "want » *.service « got » $dm «" ;; esac
    # Every cell must name a file manager. A desktop that boots without one is
    # the specific gap this row exists to close, so an empty cell is a failure
    # rather than a merely thinner desktop.
    apps="$(with_family "$fam" gui_app_packages "$de")"
    if [ -n "$apps" ]; then ok "$fam/$de apps non-empty"; else bad "$fam/$de apps non-empty" "want » packages « got » (empty) «"; fi
  done
  sess="$(with_family dnf gui_session_candidates "$de")"
  if [ -n "$sess" ]; then ok "$de session candidates non-empty"; else bad "$de session candidates non-empty" "want » candidates « got » (empty) «"; fi
done < <(grep -vE '^[[:space:]]*(#|$)' "$REPO/shared/desktops")

echo "gui-lib — family-keyed VNC machinery:"
assert_eq "dnf session starter" "/usr/libexec/vncsession-start"      "$(with_family dnf gui_vncsession_start)"
assert_eq "apt session starter" "/usr/libexec/tigervncsession-start" "$(with_family apt gui_vncsession_start)"
assert_eq "dnf pidfile"         "/run/vncsession-:1.pid"             "$(with_family dnf gui_vncsession_pidfile)"
assert_eq "apt pidfile"         "/run/tigervncsession-:1.pid"        "$(with_family apt gui_vncsession_pidfile)"

# Pinned verbatim because two of these names diverge by family in ways that look
# like typos: only Fedora capitalizes Thunar, and only the apt family namespaces
# Spectacle. A silent "fix" toward the other family's spelling fails the image
# build, since the DE application install is fail-loud.
echo "gui-lib — family-divergent application names:"
assert_eq "dnf/kde apps"  "dolphin kate ark gwenview spectacle"                     "$(with_family dnf gui_app_packages kde)"
assert_eq "apt/kde apps"  "dolphin kate ark gwenview kde-spectacle"                 "$(with_family apt gui_app_packages kde)"
assert_eq "dnf/xfce apps" "Thunar mousepad xarchiver ristretto xfce4-screenshooter" "$(with_family dnf gui_app_packages xfce)"
assert_eq "apt/xfce apps" "thunar mousepad xarchiver ristretto xfce4-screenshooter" "$(with_family apt gui_app_packages xfce)"
assert_eq "dnf agent"     "spice-vdagent"                                           "$(with_family dnf gui_agent_packages)"
assert_eq "apt agent"     "spice-vdagent"                                           "$(with_family apt gui_agent_packages)"
assert_eq "dnf browser"   "firefox"                                                 "$(with_family dnf gui_browser_packages)"
assert_eq "apt browser"   "firefox-esr"                                             "$(with_family apt gui_browser_packages)"

# The browser's package name and its desktop-file id are one fact per family:
# gui.sh decides whether to pin a launcher from the package, then names the file
# from the id, and kde-panel.sh fails the build if that file is absent. Pin both
# halves so a rename cannot move one without the other.
echo "gui-lib — the browser package and its desktop id agree per family:"
assert_eq "dnf browser desktop id" "org.mozilla.firefox.desktop" "$(with_family dnf gui_browser_desktop_id)"
assert_eq "apt browser desktop id" "firefox-esr.desktop"         "$(with_family apt gui_browser_desktop_id)"
for fam in dnf apt; do
  pkg="$(with_family "$fam" gui_browser_packages)"
  id="$(with_family "$fam" gui_browser_desktop_id)"
  # The id is not derivable from the package name (dnf reverses the domain), so
  # the check is that both are populated and the id is a .desktop file.
  case "$id" in *.desktop) ok "$fam browser id is a desktop file ($id)" ;; *) bad "$fam browser id is a desktop file" "want » *.desktop « got » $id «" ;; esac
  # gui.sh passes this list accessor's output to pkg_installed as ONE argument,
  # which is only correct while every branch returns a single token.
  assert_eq "$fam browser package list is a single token" 1 "$(printf '%s' "$pkg" | wc -w | tr -d ' ')"
done

echo "gui-lib — gui_require_de gate:"
with_family dnf gui_require_de kde; rc=$?
assert_eq "kde accepted" 0 "$rc"
with_family dnf gui_require_de cinnamon; rc=$?
if [ "$rc" -ne 0 ]; then ok "unknown de hard-fails"; else bad "unknown de hard-fails" "want » rc!=0 « got » rc=0 «"; fi

# The lib's supported set and shared/desktops must not drift apart: the
# Makefile validates against the file, the lib is the in-VM backstop.
echo "gui-lib — shared/desktops ↔ gui_require_de lockstep:"
while IFS= read -r de; do
  with_family dnf gui_require_de "$de"; rc=$?
  assert_eq "desktops-file token '$de' accepted by lib" 0 "$rc"
done < <(grep -vE '^[[:space:]]*(#|$)' "$REPO/shared/desktops")

echo; echo "  $pass passed, $fail failed"; [ "$fail" -eq 0 ]
