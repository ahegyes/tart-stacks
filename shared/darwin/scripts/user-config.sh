#!/usr/bin/env bash
# user-config.sh (darwin) — root-privileged VM config: PATH activation, the
# /mnt/shared parity link for Tart --dir shares, and the per-boot runtime dir the
# forwarded agent sockets bind into.
#
# No chsh peer: zsh is already the default shell on macOS.
set -euo pipefail

# Overridable root prefix, empty in production so every path below resolves
# exactly as written. Tests point it at a temp directory instead — the same
# seam family-lib.sh sets with TART_GUEST_DAEMON_PLIST/TART_GUEST_AGENT_PLIST
# for testability. One prefix here, not one override per path, because every
# path below is a system location, not an individually meaningful knob.
TART_ROOT="${TART_ROOT:-}"

TARGET_USER="${SUDO_USER:-admin}"
TARGET_HOME="${TART_ROOT}/Users/${TARGET_USER}"

# .zshenv loads before .zshrc and for non-interactive shells too, which is the
# load-bearing case: `ssh <vm> <cmd>` runs the login shell and reads only
# .zshenv, so mise's activate hook in .zshrc never fires there.
ZSHENV="${TARGET_HOME}/.zshenv"
if [ ! -f "${ZSHENV}" ] || ! grep -q 'mise/shims' "${ZSHENV}"; then
  cat >> "${ZSHENV}" <<'EOF'
# Added by tart-stacks provisioning — user-local binaries and mise's shims on
# PATH, including for non-interactive `ssh <vm> <cmd>` sessions.
export PATH="$HOME/.local/bin:$HOME/.local/share/mise/shims:/opt/homebrew/bin:$PATH"
EOF
  chown "${TARGET_USER}:staff" "${ZSHENV}"
fi
chown "${TARGET_USER}:staff" "${TARGET_HOME}/.zshrc"
chown -R "${TARGET_USER}:staff" "${TARGET_HOME}/.config"

# Tart surfaces every --dir share under /Volumes/My Shared Files/<name>, while the
# linux images serve them at /mnt/shared/<name>. Matching the path means a mounts
# entry and any tooling that references it work identically on either platform.
# The sealed system volume forbids creating a symlink at /, so synthetic.conf is
# the supported mechanism — and it is WRITE-ONCE: the first value materialises at
# the next boot and later edits never update it, so a wrong value here needs a
# rebuild, not a fix. Two hops because synthetic.conf cannot create a nested path.
echo "==> Registering /mnt/shared for Tart directory shares..."
install -d -m 755 "${TART_ROOT}/opt/tart/mnt"
ln -sfn "/Volumes/My Shared Files" "${TART_ROOT}/opt/tart/mnt/shared"
printf 'mnt\t/opt/tart/mnt\n' > "${TART_ROOT}/etc/synthetic.conf"
chmod 644 "${TART_ROOT}/etc/synthetic.conf"

# /var/run is cleared at boot on macOS exactly as /run is on linux, so the parent
# of the per-agent sockets has to be recreated every boot — this is the tmpfiles.d
# analogue. The dev user owns it because sshd binds the socket as the session user
# and a root-owned parent refuses the bind with EACCES, which the generated SSH
# config's LogLevel ERROR hides.
echo "==> Registering /var/run/tart for forwarded agent sockets..."
cat > "${TART_ROOT}/Library/LaunchDaemons/tart-stacks-runtime-dir.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>tart-stacks-runtime-dir</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/bin/install</string>
        <string>-d</string><string>-m</string><string>700</string>
        <string>-o</string><string>${TARGET_USER}</string>
        <string>-g</string><string>staff</string>
        <string>/var/run/tart</string>
    </array>
    <key>RunAtLoad</key><true/>
</dict>
</plist>
EOF
chmod 644 "${TART_ROOT}/Library/LaunchDaemons/tart-stacks-runtime-dir.plist"
launchctl enable system/tart-stacks-runtime-dir

echo "==> user-config.sh complete."
