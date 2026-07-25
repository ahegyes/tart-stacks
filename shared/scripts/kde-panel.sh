#!/usr/bin/env bash
# kde-panel.sh — shadow Plasma's default-panel layout template so its pinned
# launchers describe what this image actually installs. Run by gui.sh for the
# kde DE only; standalone so its transform is testable without a desktop.
#
# Plasma's unconfigured icon-tasks widget falls back to built-in launchers that
# include Discover, even though no software centre is installed — a blank,
# unopenable icon. Rewriting the widget's launcher list is the only way to
# remove it, since the pin comes from the widget's defaults rather than from any
# file this repository writes.
#
# The session resolves /usr/local/share ahead of /usr/share, so a template
# placed there shadows the packaged one without editing a package-owned file.
# That precedence is asserted below rather than assumed: if it ever stops
# holding, the packaged panel returns silently, which is the exact outcome this
# script exists to prevent.
#
# Usage: kde-panel.sh <browser-desktop-id|""> [source-layout.js] [target-dir]
#   The browser id is empty when the optional browser was skipped for this
#   family (Ubuntu has no firefox-esr); every other launcher is mandatory.
set -euo pipefail

prog="${0##*/}"

BROWSER_DESKTOP="${1?usage: $0 <browser-desktop-id|\"\"> [source] [target]}"
PANEL_SOURCE="${2:-/usr/share/plasma/layout-templates/org.kde.plasma.desktop.defaultPanel/contents/layout.js}"
PANEL_TARGET="${3:-/usr/local/share/plasma/layout-templates/org.kde.plasma.desktop.defaultPanel}"
APPLICATIONS_DIR="${TART_APPLICATIONS_DIR:-/usr/share/applications}"

# The anchor is defined once and reused by both the count check and the
# transform. Spelling it twice let an edit satisfy one and miss the other,
# shadowing the packaged template with an unpatched copy.
PANEL_ANCHOR='^[[:space:]]*panel\.addWidget\("org\.kde\.plasma\.icontasks"\)[[:space:]]*$'

[ -f "$PANEL_SOURCE" ] || {
  echo "$prog: ERROR: KDE default-panel layout is missing at ${PANEL_SOURCE}." >&2
  exit 1
}

anchor_count="$(grep -Ec "$PANEL_ANCHOR" "$PANEL_SOURCE" || true)"
[ "$anchor_count" -eq 1 ] || {
  echo "$prog: ERROR: KDE default-panel layout must contain exactly one unconfigured icon-tasks anchor; found ${anchor_count} in ${PANEL_SOURCE}." >&2
  exit 1
}

launchers=""
if [ -n "$BROWSER_DESKTOP" ]; then
  # A browser the family genuinely lacks is omitted upstream by passing an empty
  # id. Reaching here with an id whose desktop file is absent means the package
  # installed under a name this script does not know — an unpinned browser on an
  # image built to carry one, which is the defect, not a capability to drop.
  [ -f "${APPLICATIONS_DIR}/${BROWSER_DESKTOP}" ] || {
    echo "$prog: ERROR: browser desktop file '${BROWSER_DESKTOP}' is missing from ${APPLICATIONS_DIR}, but the browser was installed for this family." >&2
    exit 1
  }
  launchers="applications:${BROWSER_DESKTOP}"
fi

# These correspond to fail-loud KDE packages, so a missing desktop file is a
# broken panel contract rather than an entry to omit silently.
for desktop_id in org.kde.dolphin.desktop org.kde.konsole.desktop org.kde.kate.desktop; do
  [ -f "${APPLICATIONS_DIR}/${desktop_id}" ] || {
    echo "$prog: ERROR: KDE launcher desktop file '${desktop_id}' is missing." >&2
    exit 1
  }
  [ -n "$launchers" ] && launchers="${launchers},"
  launchers="${launchers}applications:${desktop_id}"
done

install -d -m 755 "${PANEL_TARGET}/contents"
# Name is not decoration: KPackage deduplicates templates by plugin id and this
# copy wins the data-root search, so it is the only metadata Plasma sees. The
# Add Panel menu labels its entry from the plugin name with no id fallback, and
# an omitted name renders exactly the blank, clickable row this removes.
cat > "${PANEL_TARGET}/metadata.json" <<'EOF'
{
  "KPackageStructure": "Plasma/LayoutTemplate",
  "KPlugin": {
    "Id": "org.kde.plasma.desktop.defaultPanel",
    "Name": "Default Panel"
  },
  "X-Plasma-ContainmentCategories": ["panel"],
  "X-Plasma-Shell": "plasmashell"
}
EOF

# Only the launcher anchor changes; the distro template keeps ownership of panel
# height, aspect-ratio clamping, and input-method behaviour. The injected
# binding is uniquely named: this is not a JavaScript-aware transform, and a
# future template declaring its own top-level `tasks` would otherwise collide
# into a syntax error that every assertion here would still pass.
# The anchor rides ENVIRON, not -v: awk processes escape sequences in a -v
# value, which turns the ERE's `\(` into a grouping paren and stops it matching
# the literal parens it is there to find.
PANEL_ANCHOR="$PANEL_ANCHOR" awk -v launchers="$launchers" '
  $0 ~ ENVIRON["PANEL_ANCHOR"] {
    match($0, /^[[:space:]]*/)
    indent = substr($0, RSTART, RLENGTH)
    print indent "var tartStacksTasks = panel.addWidget(\"org.kde.plasma.icontasks\")"
    print indent "tartStacksTasks.currentConfigGroup = [\"General\"]"
    print indent "tartStacksTasks.writeConfig(\"launchers\", \"" launchers "\")"
    next
  }
  { print }
' "$PANEL_SOURCE" > "${PANEL_TARGET}/contents/layout.js"

grep -q "tartStacksTasks.writeConfig(\"launchers\", \"${launchers}\")" \
  "${PANEL_TARGET}/contents/layout.js" || {
  echo "$prog: ERROR: KDE panel launcher transform produced no launchers line in ${PANEL_TARGET}/contents/layout.js." >&2
  exit 1
}
chmod 644 "${PANEL_TARGET}/metadata.json" "${PANEL_TARGET}/contents/layout.js"

# Every check above proves the artifact on disk; none proves Plasma will load
# it. Ask KPackage which path the id now resolves to, so a changed XDG_DATA_DIRS
# or a relocated distro template fails the build instead of silently restoring
# the packaged panel. Skipped when the tool is absent — the assertion is a
# safeguard, not a new build dependency.
if command -v kpackagetool6 >/dev/null 2>&1; then
  resolved="$(kpackagetool6 --type Plasma/LayoutTemplate \
    --show org.kde.plasma.desktop.defaultPanel 2>/dev/null |
    awk -F': *' '/^[[:space:]]*Path[[:space:]]*:/ { print $2 }')"
  case "$resolved" in
    "${PANEL_TARGET}"*) ;;
    *)
      echo "$prog: ERROR: Plasma resolves the default-panel template to '${resolved:-nothing}', not the ${PANEL_TARGET} shadow; the packaged panel would win." >&2
      exit 1 ;;
  esac
fi

echo "$prog: panel launchers pinned: ${launchers}"
