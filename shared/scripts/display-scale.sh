#!/usr/bin/env bash
# display-scale.sh — install template for the per-boot desktop scale applier.
# gui.sh replaces the three tart-stacks placeholders before installing this as
# /usr/local/bin/tart-stacks-display-scale. It runs as the baked desktop user,
# before that boot's graphical session starts.
set -euo pipefail

DE="__TART_STACKS_DE__"
TARGET_USER="__TART_STACKS_TARGET_USER__"
TARGET_HOME="__TART_STACKS_TARGET_HOME__"
prog="${0##*/}"

usage() {
  echo "usage: $prog <factor: 1|2|3>" >&2
  exit 64
}

ini_key() { # <file> <section> <key> <set|delete> [value]
  local file="$1" section="$2" key="$3" action="$4" value="${5:-}"
  local dir source tmp

  if [ "$action" = "delete" ] && [ ! -f "$file" ]; then
    return 0
  fi

  dir="${file%/*}"
  mkdir -p "$dir"
  tmp="$(mktemp "${file}.tmp.XXXXXX")"
  source="/dev/null"
  [ -f "$file" ] && source="$file"

  if ! awk \
    -v wanted_section="$section" \
    -v wanted_key="$key" \
    -v action="$action" \
    -v wanted_value="$value" '
      function emit_key() {
        print wanted_key "=" wanted_value
        emitted = 1
      }
      BEGIN {
        in_section = 0
        found_section = 0
        emitted = 0
      }
      /^[[:space:]]*\[[^]]+\][[:space:]]*$/ {
        if (in_section && action == "set" && !emitted)
          emit_key()

        name = $0
        sub(/^[[:space:]]*\[/, "", name)
        sub(/\][[:space:]]*$/, "", name)
        in_section = (name == wanted_section)
        if (in_section)
          found_section = 1
        print
        next
      }
      {
        if (in_section && index($0, "=") != 0) {
          name = $0
          sub(/=.*/, "", name)
          gsub(/^[[:space:]]+|[[:space:]]+$/, "", name)
          if (name == wanted_key) {
            if (action == "set" && !emitted)
              emit_key()
            next
          }
        }
        print
      }
      END {
        if (in_section && action == "set" && !emitted)
          emit_key()
        if (!found_section && action == "set") {
          if (NR != 0)
            print ""
          print "[" wanted_section "]"
          emit_key()
        }
      }
    ' "$source" > "$tmp"; then
    rm -f "$tmp"
    return 1
  fi

  mv -f "$tmp" "$file"
}

kde_key() { # <file> <section> <key> <set|delete> [value]
  local file="$1" section="$2" key="$3" action="$4" value="${5:-}"

  if [ "$action" = "delete" ] && [ ! -f "$file" ]; then
    return 0
  fi

  if command -v kwriteconfig6 >/dev/null 2>&1; then
    if [ "$action" = "delete" ]; then
      kwriteconfig6 --file "$file" --group "$section" --key "$key" --delete
    else
      kwriteconfig6 --file "$file" --group "$section" --key "$key" "$value"
    fi
  else
    ini_key "$file" "$section" "$key" "$action" "$value"
  fi
}

apply_kde() {
  local factor="$1" dpi action
  local fonts="$XDG_CONFIG_HOME/kcmfonts"
  local globals="$XDG_CONFIG_HOME/kdeglobals"

  if [ "$factor" -eq 1 ]; then
    action="delete"
    dpi=""
  else
    action="set"
    dpi="$((96 * factor))"
  fi

  kde_key "$fonts" General forceFontDPI "$action" "$dpi"
  kde_key "$globals" KScreen ScaleFactor "$action" "$factor"
  # Apple's virtual GPU presents Virtual-1 on X11. If that ever changes,
  # connector-free forceFontDPI still scales fonts; only Qt widgets degrade.
  kde_key "$globals" KScreen ScreenScaleFactors "$action" "Virtual-1=${factor};"
}

apply_gnome() {
  local factor="$1"

  command -v dbus-run-session >/dev/null 2>&1 || {
    echo "$prog: dbus-run-session is required for GNOME display scaling." >&2
    return 1
  }
  command -v gsettings >/dev/null 2>&1 || {
    echo "$prog: gsettings is required for GNOME display scaling." >&2
    return 1
  }

  if [ "$factor" -eq 1 ]; then
    dbus-run-session -- sh -eu -c '
      gsettings reset org.gnome.desktop.interface scaling-factor
      gsettings reset org.gnome.desktop.interface text-scaling-factor
    '
  else
    # The nested shell owns $1; keeping both writes on one private bus lets
    # dconf update its binary user database safely before a session exists.
    # shellcheck disable=SC2016
    dbus-run-session -- sh -eu -c '
      gsettings set org.gnome.desktop.interface scaling-factor "$1"
      gsettings reset org.gnome.desktop.interface text-scaling-factor
    ' tart-stacks-display-scale "$factor"
  fi
}

apply_xfce() {
  local factor="$1"
  local file="$XDG_CONFIG_HOME/xfce4/xfconf/xfce-perchannel-xml/xsettings.xml"

  command -v python3 >/dev/null 2>&1 || {
    echo "$prog: python3 is required for XFCE display scaling." >&2
    return 1
  }

  python3 - "$file" "$factor" <<'PY'
import os
import stat
import sys
import tempfile
import xml.etree.ElementTree as ET
from pathlib import Path

path = Path(sys.argv[1])
factor = int(sys.argv[2])

if factor == 1 and not path.exists():
    raise SystemExit(0)

if path.exists():
    parser = ET.XMLParser(target=ET.TreeBuilder(insert_comments=True))
    try:
        tree = ET.parse(path, parser=parser)
    except (ET.ParseError, OSError) as error:
        raise SystemExit(f"{path}: cannot parse existing XFCE settings: {error}")
    root = tree.getroot()
    if root.tag != "channel" or root.get("name") != "xsettings":
        raise SystemExit(f"{path}: expected an xsettings xfconf channel")
else:
    root = ET.Element("channel", {"name": "xsettings", "version": "1.0"})
    tree = ET.ElementTree(root)

changed = False


def groups_named(name):
    return [
        child
        for child in root
        if child.tag == "property" and child.get("name") == name
    ]


def remove_property(group_name, key):
    global changed
    for group in list(groups_named(group_name)):
        for child in list(group):
            if child.tag == "property" and child.get("name") == key:
                group.remove(child)
                changed = True
        if len(group) == 0 and not (group.text or "").strip():
            root.remove(group)
            changed = True


def set_property(group_name, key, value):
    global changed
    groups = groups_named(group_name)
    if groups:
        group = groups[0]
    else:
        group = ET.SubElement(
            root, "property", {"name": group_name, "type": "empty"}
        )
        groups = [group]
        changed = True

    matches = []
    for candidate_group in groups:
        for child in list(candidate_group):
            if child.tag == "property" and child.get("name") == key:
                matches.append((candidate_group, child))

    if matches:
        keep_group, keep = matches[0]
        if keep_group is not group:
            keep_group.remove(keep)
            group.append(keep)
            changed = True
        if keep.get("type") != "int" or keep.get("value") != value:
            keep.set("type", "int")
            keep.set("value", value)
            changed = True
        for duplicate_group, duplicate in matches[1:]:
            duplicate_group.remove(duplicate)
            changed = True
    else:
        ET.SubElement(
            group, "property", {"name": key, "type": "int", "value": value}
        )
        changed = True


if factor == 1:
    remove_property("Gdk", "WindowScalingFactor")
    remove_property("Xft", "DPI")
else:
    set_property("Gdk", "WindowScalingFactor", str(factor))
    set_property("Xft", "DPI", str(96 * factor))

if not changed:
    raise SystemExit(0)

path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
fd, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
try:
    with os.fdopen(fd, "wb") as output:
        tree.write(output, encoding="utf-8", xml_declaration=True)
        output.write(b"\n")
    if path.exists():
        os.chmod(temporary, stat.S_IMODE(path.stat().st_mode))
    os.replace(temporary, path)
except BaseException:
    try:
        os.unlink(temporary)
    except FileNotFoundError:
        pass
    raise
PY
}

[ "$#" -eq 1 ] || usage
case "$1" in
  1|2|3) factor="$1" ;;
  *) usage ;;
esac

actual_user="$(id -un)"
if [ "$actual_user" != "$TARGET_USER" ]; then
  echo "$prog: must run as '$TARGET_USER' (running as '$actual_user')." >&2
  exit 1
fi

export HOME="$TARGET_HOME"
export XDG_CONFIG_HOME="$TARGET_HOME/.config"
umask 077
mkdir -p "$XDG_CONFIG_HOME"

case "$DE" in
  kde) apply_kde "$factor" ;;
  gnome) apply_gnome "$factor" ;;
  xfce) apply_xfce "$factor" ;;
  *)
    echo "$prog: unsupported baked desktop '$DE'." >&2
    exit 1
    ;;
esac

# This is a pre-session tool: tart-up runs it before the display manager creates
# a session, which is what makes the settings authoritative. A session already
# running holds these values in memory and rewrites its own config on exit, so a
# hand-run inside a live desktop writes correctly and changes nothing visible —
# and exits 0 doing it. Say so rather than look like it worked.
if pgrep -u "$TARGET_USER" -x xfconfd    >/dev/null 2>&1 ||
   pgrep -u "$TARGET_USER" -x plasmashell >/dev/null 2>&1 ||
   pgrep -u "$TARGET_USER" -x gnome-shell >/dev/null 2>&1; then
  echo "$prog: a desktop session is already running; the new scale applies to the next session." >&2
fi
