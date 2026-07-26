#!/usr/bin/env bash
# user-config.sh — Root-privileged VM config finalization: default shell,
# PATH activation, and the virtiofs auto-mount for Tart --dir shares.
# Runs as root via sudo (chsh + /etc/fstab require it).

set -euo pipefail

TARGET_USER="${SUDO_USER:-admin}"
TARGET_HOME="/home/${TARGET_USER}"

echo "==> Setting zsh as default shell for ${TARGET_USER}..."
chsh -s /usr/bin/zsh "${TARGET_USER}"

# Activate mise in bash too — so non-zsh sessions (SSH command invocations,
# scripts, manual `bash`) still get per-directory tool version switching.
BASHRC="${TARGET_HOME}/.bashrc"
if [ ! -f "${BASHRC}" ] || ! grep -q "mise activate" "${BASHRC}"; then
  cat >> "${BASHRC}" <<'EOF'
# mise activation — added by tart-stacks provisioning.
command -v mise >/dev/null 2>&1 && eval "$(mise activate bash)"
EOF
  chown "${TARGET_USER}:${TARGET_USER}" "${BASHRC}"
fi

# Ensure ~/.local/bin is on PATH for every zsh session. .zshenv loads before
# .zshrc and runs for both interactive and non-interactive shells (so PATH is
# set even when an editor, mise, or another tool spawns a non-interactive zsh).
ZSHENV="${TARGET_HOME}/.zshenv"
if [ ! -f "${ZSHENV}" ] || ! grep -q "HOME/.local/bin" "${ZSHENV}"; then
  cat >> "${ZSHENV}" <<'EOF'
# Added by tart-stacks provisioning — ensures user-local binaries are on PATH.
export PATH="$HOME/.local/bin:$PATH"
EOF
  chown "${TARGET_USER}:${TARGET_USER}" "${ZSHENV}"
fi

# Verify provisioned config files are owned by the target user.
chown "${TARGET_USER}:${TARGET_USER}" "${TARGET_HOME}/.zshrc"
chown -R "${TARGET_USER}:${TARGET_USER}" "${TARGET_HOME}/.config"

# Auto-mount Tart's virtiofs directory shares at boot. Every `tart run --dir`
# share (e.g. attached by tart-up from ~/.config/tart-stacks/mounts) surfaces
# under one device — com.apple.virtio-fs.automount — as /mnt/shared/<name>.
# `exec` overrides the noexec that `user` implies, so an installer or other
# tooling on the share can run directly. nosuid,nodev (also implied by `user`) intentionally
# stay, and per-share read-only is enforced by Tart (--dir=<name>:<path>:ro).
mkdir -p /mnt/shared
if ! grep -qF 'com.apple.virtio-fs.automount' /etc/fstab 2>/dev/null; then
  echo 'com.apple.virtio-fs.automount /mnt/shared virtiofs rw,relatime,user,exec,nofail 0 0' >> /etc/fstab
  echo "==> registered virtiofs auto-mount at /mnt/shared in /etc/fstab"
fi

# `nofail` above stops a shareless boot from FAILING; it does not stop the UNIT
# from failing. Without an attached device the mount errors out and systemd holds
# the VM at `degraded` for the whole boot, with a red "Failed Units: 1" on every
# login — and since mounts are opt-in, that was the default state of every VM.
# The condition is evaluated at unit start, so a boot WITH a share still mounts
# it; /sys/fs/virtiofs holds one entry per attached device, which makes an empty
# directory exactly "no share on this boot".
echo "==> Skipping the virtiofs mount on boots with no share attached..."
install -d -m 755 /etc/systemd/system/mnt-shared.mount.d
cat > /etc/systemd/system/mnt-shared.mount.d/tart-stacks-skip-when-absent.conf <<'EOF'
# tart-stacks — skip /mnt/shared when the host attached no --dir share, so a
# shareless boot reports `running` instead of `degraded`.
[Unit]
ConditionPathExistsGlob=/sys/fs/virtiofs/*
EOF
chmod 644 /etc/systemd/system/mnt-shared.mount.d/tart-stacks-skip-when-absent.conf

# Additional forwarded SSH agents arrive as RemoteForwards at
# /run/tart/agent-<name>.sock (the paths tart-ssh-sync emits for every agent
# past the primary). sshd binds the socket as the session user but never creates
# its parent, and /run is root-owned 0755 — so the forward failed with EACCES,
# silently, because the same generated block sets LogLevel ERROR. /run is a
# tmpfs, so tmpfiles.d is what owns the directory across boots; the dev user owns
# it because a root-owned 0755 parent still refuses the bind.
echo "==> Registering /run/tart for forwarded agent sockets..."
install -d -m 755 /etc/tmpfiles.d
cat > /etc/tmpfiles.d/tart-stacks.conf <<EOF
# tart-stacks — parent directory for the per-session SSH agent sockets that
# tart-ssh-sync's RemoteForward lines bind. Recreated every boot (/run is tmpfs).
d /run/tart 0700 ${TARGET_USER} ${TARGET_USER} -
EOF
chmod 644 /etc/tmpfiles.d/tart-stacks.conf
# Applied now as well as at every boot: it proves the line parses while the build
# can still fail, rather than at some clone's first multi-agent login.
systemd-tmpfiles --create /etc/tmpfiles.d/tart-stacks.conf

echo "==> user-config.sh complete."
