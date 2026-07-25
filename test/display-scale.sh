#!/usr/bin/env bash
# Behavioral tests for the exact guest display-scale install template. Each DE
# gets its placeholders baked into a temporary copy and writes only under a
# temporary target home; desktop tools are mocked where no session can exist.
set -uo pipefail

TEST_DIR=$(cd -P "$(dirname "$0")" >/dev/null 2>&1 && pwd)
REPO=$(cd -P "$TEST_DIR/.." >/dev/null 2>&1 && pwd)
TEMPLATE="$REPO/shared/scripts/display-scale.sh"

pass=0 fail=0
ok()  { pass=$((pass + 1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  FAIL %s\n         %s\n' "$1" "$2"; }
assert_eq()       { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "want » $2 « got » $3 «"; fi; }
assert_contains() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "want » $3 « in: $2" ;; esac; }
assert_absent()   { case "$2" in *"$3"*) bad "$1" "should NOT contain » $3 «" ;; *) ok "$1" ;; esac; }
assert_file_absent() {
  if [ ! -e "$2" ]; then ok "$1"; else bad "$1" "should not exist: $2"; fi
}
assert_rc() {
  if [ "$rc" -eq "$2" ]; then ok "$1"; else bad "$1" "want rc=$2 got rc=$rc"; fi
}
line_count() { grep -Ec "$2" "$1" 2>/dev/null || true; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
OUT="$WORK/stdout"
ERR="$WORK/stderr"
CURRENT_USER="$(id -un)"

instantiate() { # <de> <target-user> <target-home> <output>
  sed \
    -e "s|__TART_STACKS_DE__|$1|g" \
    -e "s|__TART_STACKS_TARGET_USER__|$2|g" \
    -e "s|__TART_STACKS_TARGET_HOME__|$3|g" \
    "$TEMPLATE" > "$4"
  chmod 755 "$4"
}

run_scale() { # <script> <PATH> [argv...]
  local script="$1" run_path="$2"
  shift 2
  rc=0
  PATH="$run_path" "$BASH" "$script" "$@" >"$OUT" 2>"$ERR" || rc=$?
}

# A deliberately narrow PATH guarantees KDE exercises the awk fallback even
# on a developer machine that has Plasma tools installed.
FALLBACK_BIN="$WORK/fallback-bin"
mkdir -p "$FALLBACK_BIN"
for tool in awk id mkdir mktemp mv rm; do
  ln -s "$(command -v "$tool")" "$FALLBACK_BIN/$tool"
done

echo "display-scale — template + invocation contract:"
KDE_HOME="$WORK/kde-home"
KDE_SCRIPT="$WORK/kde-scale"
instantiate kde "$CURRENT_USER" "$KDE_HOME" "$KDE_SCRIPT"
assert_absent "instantiation replaces every placeholder" "$(cat "$KDE_SCRIPT")" "__TART_STACKS_"

run_scale "$KDE_SCRIPT" "$FALLBACK_BIN"
assert_rc "missing factor → usage exit 64" 64
run_scale "$KDE_SCRIPT" "$FALLBACK_BIN" 2 extra
assert_rc "extra argument → usage exit 64" 64
for invalid in 0 4 2.0 retina; do
  run_scale "$KDE_SCRIPT" "$FALLBACK_BIN" "$invalid"
  assert_rc "invalid factor '$invalid' → usage exit 64" 64
done

WRONG_SCRIPT="$WORK/wrong-user-scale"
WRONG_HOME="$WORK/wrong-user-home"
instantiate kde "not-${CURRENT_USER}" "$WRONG_HOME" "$WRONG_SCRIPT"
run_scale "$WRONG_SCRIPT" "$FALLBACK_BIN" 2
assert_rc "baked target-user mismatch → exit 1" 1
assert_contains "target-user mismatch names required user" "$(cat "$ERR")" "must run as 'not-${CURRENT_USER}'"
assert_file_absent "target-user mismatch writes no KDE config" "$WRONG_HOME/.config/kcmfonts"

RESET_HOME="$WORK/kde-empty-reset"
RESET_SCRIPT="$WORK/kde-empty-reset-scale"
instantiate kde "$CURRENT_USER" "$RESET_HOME" "$RESET_SCRIPT"
run_scale "$RESET_SCRIPT" "$FALLBACK_BIN" 1
assert_rc "KDE factor 1 with no prior config → exit 0" 0
assert_file_absent "KDE factor 1 does not create kcmfonts" "$RESET_HOME/.config/kcmfonts"
assert_file_absent "KDE factor 1 does not create kdeglobals" "$RESET_HOME/.config/kdeglobals"

# With no KConfig tool on PATH there is nothing to write with. KDE images ship
# one by construction, so this is the "wrong image" case: fail loudly rather
# than hand-roll a parser for a format whose group headers nest.
echo "display-scale — KDE without a KConfig tool:"
run_scale "$KDE_SCRIPT" "$FALLBACK_BIN" 2
assert_rc       "no kwriteconfig → nonzero" 1
assert_contains "no kwriteconfig → names both tools" "$(cat "$ERR")" "kwriteconfig6 nor kwriteconfig5"

echo "display-scale — KDE writes through the KConfig tool:"
KWRITE_BIN="$WORK/kwrite-bin"
mkdir -p "$KWRITE_BIN" "$WORK/kwrite-home/.config"
KWRITE_CALLS="$WORK/kwrite-calls"
export KWRITE_CALLS
cat > "$KWRITE_BIN/kwriteconfig6" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$KWRITE_CALLS"
EOF
chmod 755 "$KWRITE_BIN/kwriteconfig6"
KWRITE_SCRIPT="$WORK/kwrite-scale"
instantiate kde "$CURRENT_USER" "$WORK/kwrite-home" "$KWRITE_SCRIPT"
: > "$KWRITE_CALLS"
run_scale "$KWRITE_SCRIPT" "$KWRITE_BIN:/usr/bin:/bin" 2
assert_rc "KDE with kwriteconfig6 factor 2 → exit 0" 0
kwrite_calls="$(cat "$KWRITE_CALLS")"
assert_eq "KDE preferred editor receives three writes" 3 "$(wc -l < "$KWRITE_CALLS" | tr -d ' ')"
assert_contains "kwrite writes verified font key" "$kwrite_calls" "--group General --key forceFontDPI 192"
assert_contains "kwrite writes verified global scale key" "$kwrite_calls" "--group KScreen --key ScaleFactor 2"
assert_contains "kwrite writes verified connector key" "$kwrite_calls" "--key ScreenScaleFactors Virtual-1=2;"

# Deletes deliberately require existing files: the applier must not make empty
# KDE configs merely to reset defaults on a fresh clone.
: > "$WORK/kwrite-home/.config/kcmfonts"
: > "$WORK/kwrite-home/.config/kdeglobals"
: > "$KWRITE_CALLS"
run_scale "$KWRITE_SCRIPT" "$KWRITE_BIN:/usr/bin:/bin" 1
assert_rc "KDE with kwriteconfig6 factor 1 → exit 0" 0
kwrite_calls="$(cat "$KWRITE_CALLS")"
assert_eq "KDE preferred editor receives three deletes" 3 "$(grep -c -- '--delete' "$KWRITE_CALLS")"
assert_contains "kwrite reset deletes font key" "$kwrite_calls" "--group General --key forceFontDPI --delete"
assert_contains "kwrite reset deletes global scale key" "$kwrite_calls" "--group KScreen --key ScaleFactor --delete"
assert_contains "kwrite reset deletes connector key" "$kwrite_calls" "--key ScreenScaleFactors --delete"

# Plasma 5 images carry kwriteconfig5 instead; same CLI, same contract.
echo "display-scale — KDE falls back to kwriteconfig5:"
KWRITE5_BIN="$WORK/kwrite-bin"
mkdir -p "$KWRITE5_BIN" "$WORK/kwrite-home/.config"
KWRITE_CALLS="$WORK/kwrite-calls"
export KWRITE_CALLS
cat > "$KWRITE5_BIN/kwriteconfig5" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$KWRITE_CALLS"
EOF
chmod 755 "$KWRITE5_BIN/kwriteconfig5"
KWRITE_SCRIPT="$WORK/kwrite-scale"
instantiate kde "$CURRENT_USER" "$WORK/kwrite-home" "$KWRITE_SCRIPT"
: > "$KWRITE_CALLS"
run_scale "$KWRITE_SCRIPT" "$KWRITE5_BIN:/usr/bin:/bin" 2
assert_rc "KDE with kwriteconfig5 factor 2 → exit 0" 0
kwrite_calls="$(cat "$KWRITE_CALLS")"
assert_eq "KDE preferred editor receives three writes" 3 "$(wc -l < "$KWRITE_CALLS" | tr -d ' ')"
assert_contains "kwrite writes verified font key" "$kwrite_calls" "--group General --key forceFontDPI 192"
assert_contains "kwrite writes verified global scale key" "$kwrite_calls" "--group KScreen --key ScaleFactor 2"
assert_contains "kwrite writes verified connector key" "$kwrite_calls" "--key ScreenScaleFactors Virtual-1=2;"

# Deletes deliberately require existing files: the applier must not make empty
# KDE configs merely to reset defaults on a fresh clone.
: > "$WORK/kwrite-home/.config/kcmfonts"
: > "$WORK/kwrite-home/.config/kdeglobals"
: > "$KWRITE_CALLS"
run_scale "$KWRITE_SCRIPT" "$KWRITE5_BIN:/usr/bin:/bin" 1
assert_rc "KDE with kwriteconfig5 factor 1 → exit 0" 0
kwrite_calls="$(cat "$KWRITE_CALLS")"
assert_eq "KDE preferred editor receives three deletes" 3 "$(grep -c -- '--delete' "$KWRITE_CALLS")"
assert_contains "kwrite reset deletes font key" "$kwrite_calls" "--group General --key forceFontDPI --delete"
assert_contains "kwrite reset deletes global scale key" "$kwrite_calls" "--group KScreen --key ScaleFactor --delete"
assert_contains "kwrite reset deletes connector key" "$kwrite_calls" "--key ScreenScaleFactors --delete"

echo "display-scale — GNOME private dconf session:"
GNOME_BIN="$WORK/gnome-bin"
mkdir -p "$GNOME_BIN"
GNOME_CALLS="$WORK/gnome-calls"
export GNOME_CALLS
cat > "$GNOME_BIN/dbus-run-session" <<'EOF'
#!/usr/bin/env bash
echo "dbus-run-session" >> "$GNOME_CALLS"
[ "${1:-}" = "--" ] && shift
exec "$@"
EOF
cat > "$GNOME_BIN/gsettings" <<'EOF'
#!/usr/bin/env bash
printf 'gsettings %s\n' "$*" >> "$GNOME_CALLS"
EOF
chmod 755 "$GNOME_BIN/dbus-run-session" "$GNOME_BIN/gsettings"
GNOME_SCRIPT="$WORK/gnome-scale"
instantiate gnome "$CURRENT_USER" "$WORK/gnome-home" "$GNOME_SCRIPT"

: > "$GNOME_CALLS"
run_scale "$GNOME_SCRIPT" "$GNOME_BIN:/usr/bin:/bin" 2
assert_rc "GNOME factor 2 → exit 0" 0
gnome_calls="$(cat "$GNOME_CALLS")"
assert_eq "GNOME uses one private bus for both writes" 1 "$(grep -c '^dbus-run-session$' "$GNOME_CALLS")"
assert_contains "GNOME sets integer window scale" "$gnome_calls" "gsettings set org.gnome.desktop.interface scaling-factor 2"
assert_contains "GNOME resets text scale to avoid N-squared fonts" "$gnome_calls" "gsettings reset org.gnome.desktop.interface text-scaling-factor"

: > "$GNOME_CALLS"
run_scale "$GNOME_SCRIPT" "$GNOME_BIN:/usr/bin:/bin" 3
assert_rc "GNOME rerun at factor 3 → exit 0" 0
assert_contains "GNOME rerun replaces requested window scale" "$(cat "$GNOME_CALLS")" "scaling-factor 3"

: > "$GNOME_CALLS"
run_scale "$GNOME_SCRIPT" "$GNOME_BIN:/usr/bin:/bin" 1
assert_rc "GNOME factor 1 reset → exit 0" 0
gnome_calls="$(cat "$GNOME_CALLS")"
assert_eq "GNOME reset uses one private bus" 1 "$(grep -c '^dbus-run-session$' "$GNOME_CALLS")"
assert_contains "GNOME reset removes window-scale override" "$gnome_calls" "gsettings reset org.gnome.desktop.interface scaling-factor"
assert_contains "GNOME reset removes text-scale override" "$gnome_calls" "gsettings reset org.gnome.desktop.interface text-scaling-factor"
assert_absent "GNOME factor 1 performs no set" "$gnome_calls" "gsettings set"

echo "display-scale — XFCE structured XML editor:"
# shellcheck source=/dev/null
source "$REPO/shared/scripts/gui-lib.sh"
assert_eq "XFCE scale applier dependency is python3" "python3" "$(gui_scale_packages xfce)"
assert_eq "KDE adds no scale-only package" "" "$(gui_scale_packages kde)"
assert_eq "GNOME adds no scale-only package" "" "$(gui_scale_packages gnome)"

XFCE_HOME="$WORK/xfce-home"
XFCE_FILE="$XFCE_HOME/.config/xfce4/xfconf/xfce-perchannel-xml/xsettings.xml"
XFCE_SCRIPT="$WORK/xfce-scale"
instantiate xfce "$CURRENT_USER" "$XFCE_HOME" "$XFCE_SCRIPT"
mkdir -p "${XFCE_FILE%/*}"
cat > "$XFCE_FILE" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xsettings" version="1.0">
  <!-- keep-comment -->
  <property name="Net" type="empty">
    <property name="ThemeName" type="string" value="Adwaita"/>
  </property>
  <property name="Gdk" type="empty">
    <property name="OtherGdkKey" type="int" value="7"/>
    <property name="WindowScalingFactor" type="int" value="9"/>
  </property>
  <property name="Xft" type="empty">
    <property name="Antialias" type="int" value="1"/>
    <property name="DPI" type="int" value="120"/>
  </property>
</channel>
EOF

run_scale "$XFCE_SCRIPT" "$PATH" 2
assert_rc "XFCE factor 2 → exit 0" 0
xfce_xml="$(cat "$XFCE_FILE")"
assert_contains "XFCE writes GTK window scale" "$xfce_xml" 'name="WindowScalingFactor" type="int" value="2"'
assert_contains "XFCE writes plain 192 DPI" "$xfce_xml" 'name="DPI" type="int" value="192"'
assert_contains "XFCE preserves unrelated Gdk property" "$xfce_xml" 'name="OtherGdkKey"'
assert_contains "XFCE preserves unrelated Xft property" "$xfce_xml" 'name="Antialias"'
assert_contains "XFCE preserves unrelated channel property" "$xfce_xml" 'name="ThemeName"'
assert_contains "XFCE preserves XML comments" "$xfce_xml" "<!-- keep-comment -->"

run_scale "$XFCE_SCRIPT" "$PATH" 3
assert_rc "XFCE rerun at factor 3 → exit 0" 0
xfce_xml="$(cat "$XFCE_FILE")"
assert_contains "XFCE rerun replaces GTK scale" "$xfce_xml" 'name="WindowScalingFactor" type="int" value="3"'
assert_contains "XFCE rerun replaces DPI" "$xfce_xml" 'name="DPI" type="int" value="288"'
assert_absent "XFCE rerun removes prior GTK scale" "$xfce_xml" 'name="WindowScalingFactor" type="int" value="2"'
assert_eq "XFCE rerun leaves one window-scale property" 1 \
  "$(line_count "$XFCE_FILE" 'name="WindowScalingFactor"')"
assert_eq "XFCE rerun leaves one DPI property" 1 \
  "$(line_count "$XFCE_FILE" 'name="DPI"')"

run_scale "$XFCE_SCRIPT" "$PATH" 1
assert_rc "XFCE factor 1 reset → exit 0" 0
xfce_xml="$(cat "$XFCE_FILE")"
assert_absent "XFCE reset removes window-scale property" "$xfce_xml" 'name="WindowScalingFactor"'
assert_absent "XFCE reset removes DPI property" "$xfce_xml" 'name="DPI"'
assert_contains "XFCE reset preserves non-scaling Gdk parent" "$xfce_xml" 'name="OtherGdkKey"'
assert_contains "XFCE reset preserves non-scaling Xft parent" "$xfce_xml" 'name="Antialias"'
xfce_reset="$xfce_xml"
run_scale "$XFCE_SCRIPT" "$PATH" 1
assert_eq "XFCE repeated reset is content-idempotent" "$xfce_reset" "$(cat "$XFCE_FILE")"

XFCE_EMPTY_HOME="$WORK/xfce-empty-home"
XFCE_EMPTY_FILE="$XFCE_EMPTY_HOME/.config/xfce4/xfconf/xfce-perchannel-xml/xsettings.xml"
XFCE_EMPTY_SCRIPT="$WORK/xfce-empty-scale"
instantiate xfce "$CURRENT_USER" "$XFCE_EMPTY_HOME" "$XFCE_EMPTY_SCRIPT"
run_scale "$XFCE_EMPTY_SCRIPT" "$PATH" 1
assert_rc "XFCE factor 1 with no prior XML → exit 0" 0
assert_file_absent "XFCE factor 1 does not create xsettings.xml" "$XFCE_EMPTY_FILE"

run_scale "$XFCE_EMPTY_SCRIPT" "$PATH" 2
assert_rc "XFCE creates a missing channel for factor 2" 0
xfce_xml="$(cat "$XFCE_EMPTY_FILE")"
assert_contains "XFCE new channel carries window scale" "$xfce_xml" 'name="WindowScalingFactor" type="int" value="2"'
assert_contains "XFCE new channel carries DPI" "$xfce_xml" 'name="DPI" type="int" value="192"'
run_scale "$XFCE_EMPTY_SCRIPT" "$PATH" 1
xfce_xml="$(cat "$XFCE_EMPTY_FILE")"
assert_absent "XFCE reset removes empty Gdk parent" "$xfce_xml" 'name="Gdk"'
assert_absent "XFCE reset removes empty Xft parent" "$xfce_xml" 'name="Xft"'

echo
echo "  $pass passed, $fail failed"
[ "$fail" -eq 0 ]
