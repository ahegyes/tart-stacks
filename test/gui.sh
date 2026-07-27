#!/usr/bin/env bash
# Behavioral tests for gui.sh's X11-session gate — the check that decides whether
# an OS × DE cell can be baked at all. Upstream desktops are retiring their
# X11 sessions a release at a time and this layer serves the desktop over Xvnc,
# so this gate is where that retirement surfaces, and its message is the only
# diagnosis the builder gets. The rest of gui.sh needs a booted guest with a
# desktop installed, so only this gate is driven here; the shipped block is READ
# OUT of the script rather than restated, with just its two input paths rewritten
# to fixtures — which is what makes it runnable off a build host. Plain bash, no
# framework.
set -uo pipefail

TEST_DIR=$(cd -P "$(dirname "$0")" >/dev/null 2>&1 && pwd)
REPO=$(cd -P "$TEST_DIR/.." >/dev/null 2>&1 && pwd)
GUI="$REPO/shared/linux/scripts/gui.sh"
GUILIB="$REPO/shared/linux/scripts/gui-lib.sh"

pass=0 fail=0
ok()  { pass=$((pass + 1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  FAIL %s\n         %s\n' "$1" "${2:-}"; }
assert_eq()       { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "want » $2 « got » $3 «"; fi; }
assert_contains() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "want » $3 « in: $2" ;; esac; }

WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT

# The gate itself, lifted out and run for real. Only the two paths it reads are
# rewritten — the xsessions directory it probes and the os-release it names the
# release from — so the resolution order, the refusal and its wording are all the
# shipped ones.
GATE="$WORK/gate.sh"
{
  printf 'set -uo pipefail\n'
  printf '. "%s"\n' "$GUILIB"
  # shellcheck disable=SC2016  # $XS and $OSR are written INTO the fixture, for
  # the fixture to expand when it runs — not for this shell
  awk '
    /^SESSION=""$/ { emit = 1 }
    emit           { print }
    emit && /^}$/  { exit }
  ' "$GUI" | sed 's|/usr/share/xsessions|$XS|g; s|/etc/os-release|$OSR|g'
} > "$GATE"

# Only that the right block came across, so the cases below are not measuring an
# empty fixture. Whether it still refuses is theirs to establish — asserting the
# `exit 1` here would turn a behavioural regression into an extraction complaint
# and report the wrong thing.
if grep -q 'gui_session_candidates' "$GATE"; then
  ok "lifted the X11-session gate out of gui.sh ($(grep -c . "$GATE") lines)"
else
  bad "lifted the X11-session gate out of gui.sh" \
      "extraction produced $(grep -c . "$GATE") line(s) — the gate moved, or the awk anchor at test/gui.sh:38 no longer matches"
  printf '\n  %d passed, %d failed\n' "$pass" "$fail"
  exit 1
fi

OSR="$WORK/os-release"
printf 'ID=ubuntu\nVERSION_ID="26.04"\n' > "$OSR"

# gate <de> <session-file…> — "<resolved-session>" on success, "refuse" on
# failure; stderr of the run lands in $GATE_ERR.
GATE_ERR=""
gate() {
  local de="$1" rc=0 out; shift
  rm -rf "$WORK/xs"; mkdir -p "$WORK/xs"
  local f; for f in "$@"; do : > "$WORK/xs/$f"; done
  # The gate echoes nothing on success, so the resolved value is read back out of
  # the fixture's own $SESSION rather than from stdout.
  out=$(DE="$de" XS="$WORK/xs" OSR="$OSR" bash -c '. "$1"; printf "%s" "$SESSION"' _ "$GATE" 2>"$WORK/err") || rc=$?
  GATE_ERR=$(cat "$WORK/err")
  if [ "$rc" -ne 0 ]; then printf 'refuse'; else printf '%s' "$out"; fi
}

# Resolution order: most specific first. Plasma 6 splits X11 out as plasmax11;
# Plasma 5's plain `plasma` IS the X11 session, which is what Ubuntu 24.04 ships
# and Debian 13 does not — both measured on the built images, so both are real
# shapes this has to accept rather than hypotheticals.
assert_eq "kde: plasmax11 wins when both exist" "plasmax11" "$(gate kde plasmax11.desktop plasma.desktop)"
assert_eq "kde: plasma alone resolves (Plasma 5)" "plasma"  "$(gate kde plasma.desktop)"
assert_eq "kde: plasmax11 alone resolves"        "plasmax11" "$(gate kde plasmax11.desktop)"
assert_eq "gnome: gnome-xorg wins over gnome"    "gnome-xorg" "$(gate gnome gnome-xorg.desktop gnome.desktop)"
assert_eq "xfce: its single session resolves"    "xfce"      "$(gate xfce xfce.desktop)"

# A Wayland-only guest is the retirement arriving. It must refuse rather than
# bake a desktop Xvnc cannot start.
assert_eq "kde: Wayland-only session → refused"   "refuse" "$(gate kde plasmawayland.desktop)"
assert_eq "gnome: Wayland-only session → refused" "refuse" "$(gate gnome gnome-wayland.desktop)"
assert_eq "no sessions at all → refused"          "refuse" "$(gate gnome)"

# A near-miss must not be accepted: resolution is by exact session name, so a
# file that merely looks related is not a session this layer can start.
assert_eq "unrelated session file → refused"      "refuse" "$(gate kde plasma-bigscreen.desktop)"

# The refusal's whole job is telling the builder which of the two situations they
# are in, so the sessions that DID materialize have to be named.
gate gnome gnome-wayland.desktop >/dev/null
assert_contains "refusal names the DE"              "$GATE_ERR" "no X11 session for 'gnome'"
assert_contains "refusal names the release"          "$GATE_ERR" "ubuntu 26.04"
assert_contains "refusal lists what it tried"        "$GATE_ERR" "gnome-xorg gnome"
assert_contains "refusal lists what IS present"      "$GATE_ERR" "gnome-wayland.desktop"
assert_contains "refusal says why X11 is required"   "$GATE_ERR" "over Xvnc"
assert_contains "refusal offers both responses"      "$GATE_ERR" "leave the cell out"
assert_contains "refusal points at the contract"     "$GATE_ERR" "shared/linux/gui/README.md"

# "Nothing there" and "the wrong thing there" read identically without this.
gate gnome >/dev/null
assert_contains "empty xsessions dir says 'none'"    "$GATE_ERR" "present: none"

printf '\n  %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
