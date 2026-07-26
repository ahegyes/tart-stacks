#!/usr/bin/env bash
# gui-lib.sh — desktop-environment × package-family primitives for the optional
# GUI layer, mirroring distro-lib.sh: per-distro and per-DE variance lives here
# so gui.sh stays generic. SOURCED, not run — uploaded to /tmp and sourced
# AFTER distro-lib.sh (it branches on $_DISTRO_FAMILY). An unrecognized DE is a
# hard error, like an unrecognized distro in distro-lib.

# gui_require_de <de> — hard-fail unless this lib has branches for <de>.
# Keep the set in lockstep with shared/desktops (the Makefile validates
# against the file; this is the in-VM backstop for direct packer invocations).
gui_require_de() {
  case "$1" in
    kde|gnome|xfce) ;;
    *) echo "gui-lib: unsupported desktop environment '$1' (supported: kde, gnome, xfce)." >&2
       exit 1 ;;
  esac
}

# gui_require_cell <de> — hard-fail on a family x DE combination this layer cannot
# serve, ahead of any package work. Separate from gui_require_de: the DE itself is
# supported, the pairing is not.
gui_require_cell() {
  case "$_DISTRO_FAMILY/$1" in
    dnf/gnome)
      echo "gui-lib: the fedora x gnome cell is not supported. Fedora ships no GNOME X11 session from F43 on (FESCo WaylandOnlyGNOME), and this layer is Xvnc-based, so there is no session to bake. Use kde or xfce on fedora, or gnome on ubuntu/debian." >&2
      exit 1 ;;
  esac
}

# gui_pkg_install <pkg…> — like pkg_install but WITH weak deps / Recommends:
# DE metapackages express most of a working desktop (fonts, greeters, session
# helpers) through Recommends, so --no-install-recommends here would bake a
# desktop that boots to a broken shell. Fail-loud on purpose — a missing DE
# package is a broken image contract, not a droppable capability.
gui_pkg_install() {
  case "$_DISTRO_FAMILY" in
    dnf) dnf install -y "$@" ;;
    apt) DEBIAN_FRONTEND=noninteractive apt-get install -y "$@" ;;
  esac
}

# gui_purge_if_present <pkg…> — remove packages that may have ridden in on
# Recommends. Installed-state is checked first: dnf5 errors on removing a
# package that was never installed (apt merely no-ops, but the check keeps
# both paths uniform and skips pointless transactions).
gui_purge_if_present() {
  local p
  for p in "$@"; do
    case "$_DISTRO_FAMILY" in
      dnf) rpm -q "$p" >/dev/null 2>&1 && dnf remove -y "$p" ;;
      apt) dpkg -s "$p" >/dev/null 2>&1 && DEBIAN_FRONTEND=noninteractive apt-get purge -y "$p" ;;
    esac
  done
  return 0
}

# gui_packages <de> — the DE shell + display-manager package set for this family.
# Deliberately narrower than the distros' full desktop groups/tasks: the images
# are dev substrates, so this set stops at the shell, its display manager, and a
# terminal. The handful of applications a substrate still needs to be usable is
# gui_app_packages' concern, kept separate so the session machinery below stays
# readable next to it.
gui_packages() {
  case "$_DISTRO_FAMILY/$1" in
    dnf/kde)   echo "plasma-desktop plasma-workspace-x11 sddm konsole" ;;
    dnf/gnome) echo "gnome-shell gnome-session-xsession gdm gnome-terminal" ;;
    dnf/xfce)  echo "xfce4-session xfwm4 xfdesktop xfce4-panel xfce4-settings xfce4-terminal lightdm lightdm-gtk" ;;
    apt/kde)   echo "kde-plasma-desktop sddm konsole" ;;
    apt/gnome) echo "gnome-session gnome-shell gdm3 gnome-terminal" ;;
    apt/xfce)  echo "xfce4 xfce4-terminal lightdm lightdm-gtk-greeter" ;;
  esac
}

# gui_app_packages <de> — the applications that make a desktop usable rather
# than merely present: a file manager, a GUI text editor, an archive handler, an
# image viewer, and a screenshot tool. Each is the DE's own, so it inherits the
# session's theming and file associations instead of dragging in a second
# toolkit's dependency tree. Two names diverge by family and are easy to get
# wrong: Fedora packages Thunar under its upstream capitalization, and the apt
# family namespaces Spectacle as kde-spectacle. GNOME captures screenshots from
# the Shell itself, so its row deliberately names no screenshot tool.
gui_app_packages() {
  case "$_DISTRO_FAMILY/$1" in
    dnf/kde)   echo "dolphin kate ark gwenview spectacle" ;;
    dnf/gnome) echo "nautilus gnome-text-editor file-roller loupe" ;;
    dnf/xfce)  echo "Thunar mousepad xarchiver ristretto xfce4-screenshooter" ;;
    apt/kde)   echo "dolphin kate ark gwenview kde-spectacle" ;;
    apt/gnome) echo "nautilus gnome-text-editor file-roller loupe" ;;
    apt/xfce)  echo "thunar mousepad xarchiver ristretto xfce4-screenshooter" ;;
  esac
}

# gui_agent_packages — the SPICE guest agent, which is what host↔guest clipboard
# sharing in a native VM window depends on (`tart run --help` names the package).
# Its shipped udev rule starts the daemon only once the host actually exposes the
# channel device, so a headless or VNC-only boot pays nothing for it; VNC carries
# its own clipboard over RFB and does not use this at all.
gui_agent_packages() {
  case "$_DISTRO_FAMILY" in
    dnf|apt) echo "spice-vdagent" ;;
  esac
}

# gui_browser_packages — the conventional browser for this package family,
# independent of the desktop. Debian publishes Firefox as firefox-esr, while
# Ubuntu's firefox deb is a snap transition stub and firefox-esr is absent;
# gui.sh therefore sends this row through the optional package path.
gui_browser_packages() {
  case "$_DISTRO_FAMILY" in
    dnf) echo "firefox" ;;
    apt) echo "firefox-esr" ;;
  esac
}

# gui_browser_desktop_id — the desktop-file id of the browser gui_browser_packages
# installs, used by the KDE launcher pinning. It lives beside that package name
# because the two are one fact per family: a rename that moved only one of them
# leaves kde-panel.sh pinning a launcher for a file the image does not have, which
# it refuses to do — and gui.sh downgrades that refusal to the stock Plasma panel.
gui_browser_desktop_id() {
  case "$_DISTRO_FAMILY" in
    dnf) echo "org.mozilla.firefox.desktop" ;;
    apt) echo "firefox-esr.desktop" ;;
  esac
}

# gui_scale_packages <de> — runtime needed by the pre-session scale applier.
# KDE and GNOME already carry their native config tools with the desktop;
# XFCE's XML must be changed structurally while xfconfd is not running.
gui_scale_packages() {
  case "$1" in
    kde|gnome) ;;
    xfce) echo "python3" ;;
  esac
}

# gui_vnc_packages — TigerVNC server bits: Xvnc plus the packaged PAM session
# starter (vncsession on dnf, tigervncsession on apt). dbus-x11 provides
# dbus-launch, which the X session bootstrap needs on both families.
gui_vnc_packages() {
  case "$_DISTRO_FAMILY" in
    dnf) echo "tigervnc-server dbus-x11" ;;
    apt) echo "tigervnc-standalone-server tigervnc-tools dbus-x11" ;;
  esac
}

# gui_dm_unit <de> — the display-manager unit for this DE on this family.
# Enabling it also installs the display-manager.service alias, which is the
# stable name a graphics boot targets (see shared/gui/README.md).
gui_dm_unit() {
  case "$_DISTRO_FAMILY/$1" in
    dnf/kde|apt/kde)   echo "sddm.service" ;;
    dnf/gnome)         echo "gdm.service" ;;
    apt/gnome)         echo "gdm3.service" ;;
    dnf/xfce|apt/xfce) echo "lightdm.service" ;;
  esac
}

# gui_session_candidates <de> — X session names (basenames under
# /usr/share/xsessions) to try, most specific first. gui.sh resolves the first
# one present AFTER the package install and hard-fails if none is — the VNC
# layer is Xvnc-based, so a cell whose DE ships only a Wayland session is
# unsupported and must fail the build, not bake a desktop that can't start.
# Resolution reads /usr/share/xsessions, not package names — the session file is
# what a cell actually needs, and the two do not track each other.
gui_session_candidates() {
  case "$1" in
    kde)   echo "plasmax11 plasma" ;; # Plasma 6 splits X11 out (plasmax11); Plasma 5's plasma IS X11
    gnome) echo "gnome-xorg gnome" ;;
    xfce)  echo "xfce" ;;
  esac
}

# gui_vncsession_start / gui_vncsession_pidfile — the packaged TigerVNC session
# starter and the pidfile it writes for display :1. tart-stacks-vnc.service
# wraps these so the unit NAME stays uniform across families while the
# battle-tested per-distro machinery (PAM/logind session, SELinux labels on
# dnf) does the work.
gui_vncsession_start() {
  case "$_DISTRO_FAMILY" in
    dnf) echo "/usr/libexec/vncsession-start" ;;
    apt) echo "/usr/libexec/tigervncsession-start" ;;
  esac
}

gui_vncsession_pidfile() {
  case "$_DISTRO_FAMILY" in
    dnf) echo "/run/vncsession-:1.pid" ;;
    apt) echo "/run/tigervncsession-:1.pid" ;;
  esac
}
