#!/usr/bin/env bash
# gui.sh — optional desktop layer: a desktop environment, a display manager,
# and a localhost-only TigerVNC session service. Applied on top of ANY stack
# when the build runs with -var gui=true (GUI/DE arrive as environment_vars);
# a gui=false build exits at the gate below, so every stack shares one
# pipeline. What this bakes and how a graphics boot activates it is the
# engine-facing contract in shared/gui/README.md — change them together.
#
# The image stays headless by default (multi-user.target): the desktop costs
# RAM only on boots that opt in. Runs as root via sudo from Packer.
set -euo pipefail
# shellcheck source=/dev/null
source /tmp/distro-lib.sh
# shellcheck source=/dev/null
source /tmp/gui-lib.sh

if [ "${GUI:-false}" != "true" ]; then
  echo "==> gui.sh: gui=false — skipping the desktop layer."
  exit 0
fi

DE="${DE:?DE must be set when GUI=true}"
gui_require_de "$DE"

TARGET_USER="${SUDO_USER:-admin}"
TARGET_HOME="/home/${TARGET_USER}"

# Fast preflight for the one cell this layer refuses: Plasma 6 on the apt
# family, where no `plasma-x11-session` package exists to pull the X11 session
# the Xvnc layer needs. (Debian's plasma-workspace does ship an X11 session
# file, so the cell may be buildable — but nobody has run it end to end, and
# refusing here beats failing the same way after a multi-minute DE install.)
# The post-install session assert below stays the general gate.
if [ "$_DISTRO_FAMILY" = "apt" ] && [ "$DE" = "kde" ]; then
  plasma_ver="$(apt-cache policy plasma-workspace 2>/dev/null | sed -n 's/^  Candidate: //p')"
  case "$plasma_ver" in
    4:6*|4:7*)
      if ! apt-cache policy plasma-x11-session 2>/dev/null | grep -q '^  Candidate: [0-9]'; then
        echo "ERROR: no plasma-x11-session package for plasma-workspace ${plasma_ver} on this distro, so the Xvnc-based GUI layer has no X11 session it can rely on. Use de=xfce or de=gnome here, or kde on fedora/ubuntu. See shared/gui/README.md." >&2
        exit 1
      fi ;;
  esac
fi

echo "==> Installing ${DE} desktop + display manager + applications + agent + TigerVNC..."
# shellcheck disable=SC2046  # intentional word-split of the package lists
gui_pkg_install $(gui_packages "$DE") $(gui_app_packages "$DE") $(gui_agent_packages) $(gui_scale_packages "$DE") $(gui_vnc_packages)
# A browser is a droppable capability, and Ubuntu has no firefox-esr package;
# the optional path records that gap instead of failing the desktop contract
# or selecting Ubuntu's firefox snap transition stub.
# shellcheck disable=SC2046  # intentional word-split of the package list
pkg_install_optional $(gui_browser_packages)

# Resolve the X session baked for VNC (and DM autologin). Hard assert: a DE
# whose X11 session didn't materialize would bake a desktop that can't start.
SESSION=""
for s in $(gui_session_candidates "$DE"); do
  [ -f "/usr/share/xsessions/${s}.desktop" ] && { SESSION="$s"; break; }
done
[ -n "$SESSION" ] || {
  echo "ERROR: no X session found for '$DE' (tried: $(gui_session_candidates "$DE") under /usr/share/xsessions/) — this distro × DE cell is unsupported by the Xvnc-based GUI layer." >&2
  exit 1
}
echo "==> X session: ${SESSION}"

# The host applies its window's backing scale before graphical.target starts.
# Bake the DE and account into a plain per-user editor: no runtime desktop
# detection or privileged config write is needed over the guest agent.
echo "==> Installing the pre-session display scale applier..."
install -d -m 755 /usr/local/bin
sed \
  -e "s|__TART_STACKS_DE__|${DE}|g" \
  -e "s|__TART_STACKS_TARGET_USER__|${TARGET_USER}|g" \
  -e "s|__TART_STACKS_TARGET_HOME__|${TARGET_HOME}|g" \
  /tmp/display-scale.sh > /usr/local/bin/tart-stacks-display-scale
chmod 755 /usr/local/bin/tart-stacks-display-scale

# ── VNC: TigerVNC session on :1, loopback only ────────────────────────────
# No VNC password is baked (it would be a shared secret in every clone) and
# none is needed: Xvnc binds 127.0.0.1 only, so the SSH key IS the auth — the
# host reaches the desktop through a tunnel (ssh -L 5901:localhost:5901).
echo "==> Configuring the VNC session service..."
install -d -m 755 /etc/tigervnc
cat > /etc/tigervnc/vncserver.users <<EOF
# tart-stacks GUI layer — display-to-user map for the TigerVNC session
# starter behind tart-stacks-vnc.service.
:1=${TARGET_USER}
EOF

install -d -m 700 -o "${TARGET_USER}" -g "${TARGET_USER}" "${TARGET_HOME}/.vnc"
case "$_DISTRO_FAMILY" in
  dnf)
    # vncsession(8) grammar: one Xvnc option per line, no leading dash.
    cat > "${TARGET_HOME}/.vnc/config" <<EOF
session=${SESSION}
geometry=1920x1080
localhost
SecurityTypes=None
EOF
    chown "${TARGET_USER}:${TARGET_USER}" "${TARGET_HOME}/.vnc/config"
    ;;
  apt)
    # tigervncserver(1) grammar: a perl fragment (must end true, hence `1;`).
    cat > "${TARGET_HOME}/.vnc/tigervnc.conf" <<EOF
\$session = "${SESSION}";
\$geometry = "1920x1080";
\$localhost = "yes";
\$SecurityTypes = "None";
1;
EOF
    chown "${TARGET_USER}:${TARGET_USER}" "${TARGET_HOME}/.vnc/tigervnc.conf"
    ;;
esac

# One stable engine-facing unit name across families; the body wraps this
# family's packaged session starter, which opens a real PAM/logind session
# for the user (and carries the SELinux transition on dnf).
{
  cat <<EOF
# tart-stacks GUI layer — VNC desktop session, loopback-only on :5901.
# Deliberately NOT enabled: a boot that wants the desktop starts this unit
# (see shared/gui/README.md); headless boots pay nothing.
[Unit]
Description=tart-stacks VNC desktop session (display :1, 127.0.0.1:5901)
After=network.target systemd-user-sessions.service

[Service]
Type=forking
ExecStart=$(gui_vncsession_start) :1
PIDFile=$(gui_vncsession_pidfile)
EOF
  if [ "$_DISTRO_FAMILY" = "dnf" ]; then
    echo "ExecStartPre=+/usr/libexec/vncsession-restore :1"
    echo "SELinuxContext=system_u:system_r:vnc_session_t:s0"
  fi
  cat <<'EOF'

[Install]
WantedBy=multi-user.target
EOF
} > /etc/systemd/system/tart-stacks-vnc.service
chmod 644 /etc/systemd/system/tart-stacks-vnc.service

# ── Display manager: enabled but dormant ──────────────────────────────────
# Enabling registers the display-manager.service alias graphical.target pulls
# in; pinning multi-user.target as the default is what keeps it dormant — on
# the apt family the default is graphical.target, so without the pin a GUI
# image would boot a desktop even when nothing asked for one.
DM_UNIT="$(gui_dm_unit "$DE")"
echo "==> Enabling ${DM_UNIT} (dormant until a graphical.target boot)..."
systemctl enable "$DM_UNIT"
systemctl set-default multi-user.target

# Autologin is baked deliberately: 99-finalize.sh locks the account password,
# so a login greeter would be a dead end — and a console session grants
# nothing the SSH key doesn't already (NOPASSWD sudo).
echo "==> Baking ${TARGET_USER} autologin into ${DM_UNIT}..."
case "$DM_UNIT" in
  sddm.service)
    install -d -m 755 /etc/sddm.conf.d
    # sddm's documented Session form is the session desktop filename; lightdm
    # below takes the bare name — don't unify them.
    cat > /etc/sddm.conf.d/tart-stacks-autologin.conf <<EOF
[Autologin]
User=${TARGET_USER}
Session=${SESSION}.desktop
EOF
    ;;
  gdm.service|gdm3.service)
    # GDM reads one GKeyFile whose path differs per family, and duplicate
    # [daemon] groups are a parse error — merge into the shipped section.
    gdm_conf=""
    for f in /etc/gdm/custom.conf /etc/gdm3/daemon.conf /etc/gdm3/custom.conf; do
      [ -f "$f" ] && { gdm_conf="$f"; break; }
    done
    [ -n "$gdm_conf" ] || { echo "ERROR: no GDM config file found to bake autologin into." >&2; exit 1; }
    if grep -q '^\[daemon\]' "$gdm_conf"; then
      sed -i "/^\[daemon\]/a AutomaticLoginEnable=True\nAutomaticLogin=${TARGET_USER}" "$gdm_conf"
    else
      printf '\n[daemon]\nAutomaticLoginEnable=True\nAutomaticLogin=%s\n' "${TARGET_USER}" >> "$gdm_conf"
    fi
    ;;
  lightdm.service)
    install -d -m 755 /etc/lightdm/lightdm.conf.d
    cat > /etc/lightdm/lightdm.conf.d/50-tart-stacks-autologin.conf <<EOF
[Seat:*]
autologin-user=${TARGET_USER}
autologin-user-timeout=0
autologin-session=${SESSION}
EOF
    ;;
esac

# ── No screen locking, no sleep ───────────────────────────────────────────
# The locked account password makes any lock screen a walled-off session, and
# a suspended VM is just a dead VM — neither has a place in a dev image.
echo "==> Disabling screen locking and sleep..."
case "$DE" in
  kde)
    install -d -m 755 /etc/xdg
    cat > /etc/xdg/kscreenlockerrc <<'EOF'
[Daemon]
Autolock=false
LockOnResume=false
EOF

    # Pin the panel launchers to what this image installs. The browser id is
    # passed empty only when the browser is genuinely absent for this family —
    # decided by what the optional install actually left behind, not by probing
    # for the desktop file, so a package present under an unexpected name fails
    # loudly instead of silently shipping an unpinned browser.
    kde_browser_desktop=""
    if pkg_installed "$(gui_browser_packages)"; then
      case "$_DISTRO_FAMILY" in
        dnf) kde_browser_desktop="org.mozilla.firefox.desktop" ;;
        apt) kde_browser_desktop="firefox-esr.desktop" ;;
      esac
    fi
    echo "==> Pinning the KDE panel launchers..."
    bash /tmp/kde-panel.sh "$kde_browser_desktop"
    ;;
  gnome)
    # The local system db only takes effect if the active dconf profile lists
    # it — minimal bases often ship no /etc/dconf/profile/user at all, and
    # dconf's built-in default reads only user-db:user.
    install -d -m 755 /etc/dconf/profile
    if [ ! -f /etc/dconf/profile/user ]; then
      printf 'user-db:user\nsystem-db:local\n' > /etc/dconf/profile/user
    elif ! grep -q '^system-db:local$' /etc/dconf/profile/user; then
      echo 'system-db:local' >> /etc/dconf/profile/user
    fi
    install -d -m 755 /etc/dconf/db/local.d
    cat > /etc/dconf/db/local.d/00-tart-stacks-nolock <<'EOF'
[org/gnome/desktop/session]
idle-delay=uint32 0

[org/gnome/desktop/screensaver]
lock-enabled=false

[org/gnome/settings-daemon/plugins/power]
sleep-inactive-ac-type='nothing'
EOF
    dconf update
    ;;
  xfce)
    # Nothing configures a locker here; purge any that rode in on Recommends.
    gui_purge_if_present light-locker xfce4-screensaver
    ;;
esac
systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target

# ── Netpolicy hygiene ─────────────────────────────────────────────────────
# The desktop must not change the network posture: egress still flows only
# through whatever the host enforces at VM start (softnet / proxy). Two things
# a DE install drags in could fight that, so both are neutralized here.

# NetworkManager arrives as a desktop dependency on the apt family, where the
# base image's renderer (systemd-networkd / ifupdown) already owns the
# primary interface; unmanaged ethernet prevents a second DHCP client from
# fighting it. On dnf NetworkManager IS the base's manager — leave it alone.
if [ "$_DISTRO_FAMILY" = "apt" ] && [ -d /etc/NetworkManager ]; then
  install -d -m 755 /etc/NetworkManager/conf.d
  cat > /etc/NetworkManager/conf.d/tart-stacks-unmanaged.conf <<'EOF'
# tart-stacks GUI layer — the base image's network renderer keeps sole
# ownership of the interfaces; NetworkManager is only here as a desktop
# dependency. The desktop changes the display, not the network posture.
[keyfile]
unmanaged-devices=type:ethernet
EOF
fi

# mDNS broadcast/discovery daemons have no business on a confined dev VM.
for u in avahi-daemon.socket avahi-daemon.service cups-browsed.service; do
  if systemctl cat "$u" >/dev/null 2>&1; then
    echo "==> Disabling ${u} (broadcast/discovery daemon)..."
    systemctl disable --now "$u"
  fi
done

echo "==> gui.sh complete: ${DE} baked (session=${SESSION}, dm=${DM_UNIT}, vnc=tart-stacks-vnc.service on 127.0.0.1:5901)."
