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
# `nofail` makes a shareless boot a no-op (the device simply isn't attached),
# so this is harmless on any VM started without --dir.
# `exec` overrides the noexec that `user` implies, so an installer or other
# tooling on the share can run directly. nosuid,nodev (also implied by `user`) intentionally
# stay, and per-share read-only is enforced by Tart (--dir=<name>:<path>:ro).
mkdir -p /mnt/shared
if ! grep -qF 'com.apple.virtio-fs.automount' /etc/fstab 2>/dev/null; then
  echo 'com.apple.virtio-fs.automount /mnt/shared virtiofs rw,relatime,user,exec,nofail 0 0' >> /etc/fstab
  echo "==> registered virtiofs auto-mount at /mnt/shared in /etc/fstab"
fi

echo "==> user-config.sh complete."
