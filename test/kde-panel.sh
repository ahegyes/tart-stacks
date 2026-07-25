#!/usr/bin/env bash
# Behavioral tests for shared/scripts/kde-panel.sh — the Plasma default-panel
# launcher pinning. The real script runs against synthetic Plasma 5 and 6 layout
# templates in a tmpdir, so the transform that rewrites a package-owned file is
# covered without a desktop, a build, or a VM. Plain bash, no framework.
set -uo pipefail

TEST_DIR=$(cd -P "$(dirname "$0")" >/dev/null 2>&1 && pwd)
REPO=$(cd -P "$TEST_DIR/.." >/dev/null 2>&1 && pwd)
SCRIPT="$REPO/shared/scripts/kde-panel.sh"

pass=0 fail=0
ok()  { pass=$((pass + 1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  FAIL %s\n         %s\n' "$1" "${2:-}"; }
assert_contains() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "want » $3 « in: $2" ;; esac; }
assert_absent()   { case "$2" in *"$3"*) bad "$1" "should NOT contain » $3 «" ;; *) ok "$1" ;; esac; }
assert_eq()       { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "want » $2 « got » $3 «"; fi; }
assert_rc()       { if [ "$rc" -eq "$2" ]; then ok "$1"; else bad "$1" "want rc=$2 got rc=$rc"; fi; }

WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
APPS="$WORK/applications"; mkdir -p "$APPS"
# kpackagetool6 must not be found: the resolution gate is a build-time
# safeguard, and these tests exercise the transform, not a live Plasma.
STUBBIN="$WORK/bin"; mkdir -p "$STUBBIN"

# The mandatory KDE launchers, plus a browser under the Fedora id.
for d in org.kde.dolphin.desktop org.kde.konsole.desktop org.kde.kate.desktop \
         org.mozilla.firefox.desktop; do
  : > "$APPS/$d"
done

# A Plasma 6-shaped template: the anchor plus lines that must survive verbatim.
plasma6_template() {
  cat <<'JS'
var panel = new Panel
panel.location = "bottom"
panel.height = gridUnit * 3
panel.addWidget("org.kde.plasma.kickoff")
    panel.addWidget("org.kde.plasma.icontasks")
panel.addWidget("org.kde.plasma.systemtray")
panel.addWidget("org.kde.plasma.digitalclock")
JS
}

run_panel() { # <browser-id> <source> [target]
  local target="${3:-$WORK/target}"
  rm -rf "$target"
  rc=0
  OUT=$(PATH="$STUBBIN:/usr/bin:/bin" TART_APPLICATIONS_DIR="$APPS" \
    bash "$SCRIPT" "$1" "$2" "$target" 2>&1) || rc=$?
  LAYOUT="$target/contents/layout.js"
}

echo "kde-panel — happy path:"
SRC="$WORK/plasma6.js"; plasma6_template > "$SRC"
run_panel org.mozilla.firefox.desktop "$SRC"
assert_rc       "one anchor → exit 0" 0
assert_contains "browser pinned first" "$(cat "$LAYOUT")" \
  'writeConfig("launchers", "applications:org.mozilla.firefox.desktop,applications:org.kde.dolphin.desktop,applications:org.kde.konsole.desktop,applications:org.kde.kate.desktop")'
assert_absent   "Discover is not pinned" "$(cat "$LAYOUT")" "discover"
assert_contains "unrelated widgets survive" "$(cat "$LAYOUT")" 'panel.addWidget("org.kde.plasma.systemtray")'
assert_contains "panel height survives"     "$(cat "$LAYOUT")" 'panel.height = gridUnit * 3'
assert_eq       "anchor replaced, not duplicated" 0 \
  "$(grep -c '^[[:space:]]*panel\.addWidget("org\.kde\.plasma\.icontasks")[[:space:]]*$' "$LAYOUT")"
assert_contains "source indentation preserved" "$(cat "$LAYOUT")" \
  '    var tartStacksTasks = panel.addWidget'

# A future template declaring its own top-level `tasks` must not collide with
# the injected binding — the transform is textual, not JavaScript-aware, so a
# generic name would produce a syntax error every assertion here still passes.
assert_absent "injected binding is uniquely named" "$(cat "$LAYOUT")" "var tasks ="

echo "kde-panel — metadata:"
assert_contains "manifest carries the plugin id" "$(cat "$WORK/target/metadata.json")" \
  '"Id": "org.kde.plasma.desktop.defaultPanel"'
assert_contains "manifest carries a display name" "$(cat "$WORK/target/metadata.json")" \
  '"Name": "Default Panel"'

echo "kde-panel — a skipped browser omits only its own pin:"
run_panel "" "$SRC"
assert_rc       "empty browser id → exit 0" 0
assert_contains "launchers start at dolphin" "$(cat "$LAYOUT")" \
  'writeConfig("launchers", "applications:org.kde.dolphin.desktop,applications:org.kde.konsole.desktop,applications:org.kde.kate.desktop")'

echo "kde-panel — fail-loud gates:"
# An installed browser whose desktop id this script does not know is the defect
# the pinning exists to fix, not a capability to drop silently.
run_panel firefox.desktop "$SRC"
assert_rc       "unknown browser desktop id → exit 1" 1
assert_contains "unknown browser id → names the file" "$OUT" "firefox.desktop"

mv "$APPS/org.kde.dolphin.desktop" "$APPS/.dolphin.hidden"
run_panel org.mozilla.firefox.desktop "$SRC"
assert_rc       "missing mandatory launcher → exit 1" 1
assert_contains "missing launcher → names it" "$OUT" "org.kde.dolphin.desktop"
mv "$APPS/.dolphin.hidden" "$APPS/org.kde.dolphin.desktop"

MISSING="$WORK/absent.js"
run_panel org.mozilla.firefox.desktop "$MISSING"
assert_rc       "missing source template → exit 1" 1
assert_contains "missing source → names the path" "$OUT" "$MISSING"

NOANCHOR="$WORK/noanchor.js"
plasma6_template | grep -v icontasks > "$NOANCHOR"
run_panel org.mozilla.firefox.desktop "$NOANCHOR"
assert_rc       "zero anchors → exit 1" 1
assert_contains "zero anchors → reports the count" "$OUT" "found 0"

TWOANCHOR="$WORK/twoanchor.js"
{ plasma6_template; printf 'panel.addWidget("org.kde.plasma.icontasks")\n'; } > "$TWOANCHOR"
run_panel org.mozilla.firefox.desktop "$TWOANCHOR"
assert_rc       "two anchors → exit 1" 1
assert_contains "two anchors → reports the count" "$OUT" "found 2"

# An already-configured widget is not an anchor: the transform must only claim
# the unconfigured form, so a template someone already patched is left alone.
CONFIGURED="$WORK/configured.js"
plasma6_template | sed 's/^\( *\)panel\.addWidget("org\.kde\.plasma\.icontasks")$/\1var t = panel.addWidget("org.kde.plasma.icontasks")/' > "$CONFIGURED"
run_panel org.mozilla.firefox.desktop "$CONFIGURED"
assert_rc       "already-configured widget is not an anchor → exit 1" 1

echo "kde-panel — Plasma 5 template shape:"
PLASMA5="$WORK/plasma5.js"
cat > "$PLASMA5" <<'JS'
var panel = new Panel
panel.location = "bottom"
panel.addWidget("org.kde.plasma.kickoff")
panel.addWidget("org.kde.plasma.icontasks")
panel.addWidget("org.kde.plasma.systemtray")
JS
run_panel org.mozilla.firefox.desktop "$PLASMA5"
assert_rc       "plasma 5 template → exit 0" 0
assert_contains "plasma 5 launchers pinned" "$(cat "$LAYOUT")" \
  'tartStacksTasks.writeConfig("launchers", "applications:org.mozilla.firefox.desktop'
assert_contains "plasma 5 kickoff survives" "$(cat "$LAYOUT")" 'org.kde.plasma.kickoff'

echo "kde-panel — rerun is idempotent against the packaged source:"
run_panel org.mozilla.firefox.desktop "$SRC"
first="$(cat "$LAYOUT")"
run_panel org.mozilla.firefox.desktop "$SRC"
assert_eq "second run is byte-identical" "$first" "$(cat "$LAYOUT")"

echo
echo "  $pass passed, $fail failed"
[ "$fail" -eq 0 ]
