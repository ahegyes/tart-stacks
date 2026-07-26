#!/usr/bin/env bash
# user-config.sh — Root-privileged VM config finalization: default shell,
# PATH activation, and the virtiofs auto-mount for Tart --dir shares.
# Runs as root via sudo (chsh + /etc/fstab require it).

set -euo pipefail

TARGET_USER="${SUDO_USER:-admin}"
TARGET_HOME="/home/${TARGET_USER}"

echo "==> Setting zsh as default shell for ${TARGET_USER}..."
chsh -s /usr/bin/zsh "${TARGET_USER}"

# Activate mise for an interactive `bash` too, so it gets the same per-directory
# version switching as zsh. That case only: bash reads .bashrc when interactive,
# and `ssh <vm> <cmd>` runs the LOGIN shell — zsh — so neither a script nor a
# remote command is served from here. The .zshenv PATH below covers those.
BASHRC="${TARGET_HOME}/.bashrc"
if [ ! -f "${BASHRC}" ] || ! grep -q "mise activate" "${BASHRC}"; then
  cat >> "${BASHRC}" <<'EOF'
# mise activation — added by tart-stacks provisioning.
command -v mise >/dev/null 2>&1 && eval "$(mise activate bash)"
EOF
  chown "${TARGET_USER}:${TARGET_USER}" "${BASHRC}"
fi

# Put ~/.local/bin and mise's shims on PATH for every zsh session. .zshenv loads
# before .zshrc and runs for non-interactive shells too, which is the
# load-bearing case: `ssh <vm> <cmd>` runs the LOGIN shell — zsh — and reads only
# .zshenv, so mise's activate hook (which lives in .zshrc) never fires there. The
# shims are then the only thing putting php/node/npm on PATH for a remote
# command; without them `ssh <vm> composer install` finds composer in
# ~/.local/bin and dies on its `#!/usr/bin/env php` shebang. Shims come after
# ~/.local/bin so an explicitly installed binary still wins.
ZSHENV="${TARGET_HOME}/.zshenv"
if [ ! -f "${ZSHENV}" ] || ! grep -q 'mise/shims' "${ZSHENV}"; then
  cat >> "${ZSHENV}" <<'EOF'
# Added by tart-stacks provisioning — user-local binaries and mise's shims on
# PATH, including for non-interactive `ssh <vm> <cmd>` sessions.
export PATH="$HOME/.local/bin:$HOME/.local/share/mise/shims:$PATH"
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
# from failing. With no device attached the mount errors out and systemd holds the
# VM at `degraded` for the whole boot, with a red "Failed Units: 1" on every
# login — and mounts are opt-in, so that is the state of every VM started without
# a share. The condition is evaluated at unit start, so a boot WITH a share still
# mounts it.
#
# The probe is the driver's bind directory, not /sys/fs/virtiofs: the latter is a
# 6.9 ABI, and a condition that silently cannot hold would skip the mount on an
# older kernel with nothing to show for it (systemd records a skip, not a
# failure). One virtioN entry appears there per attached device.
echo "==> Skipping the virtiofs mount on boots with no share attached..."
install -d -m 755 /etc/systemd/system/mnt-shared.mount.d
cat > /etc/systemd/system/mnt-shared.mount.d/tart-stacks-skip-when-absent.conf <<'EOF'
# tart-stacks — skip /mnt/shared when the host attached no --dir share, so a
# shareless boot reports `running` instead of `degraded`.
[Unit]
ConditionPathExistsGlob=/sys/bus/virtio/drivers/virtiofs/virtio*
EOF
chmod 644 /etc/systemd/system/mnt-shared.mount.d/tart-stacks-skip-when-absent.conf

# Additional forwarded SSH agents arrive as RemoteForwards at
# /run/tart/agent-<name>.sock (the paths tart-ssh-sync emits for every agent past
# the primary). sshd binds the socket as the session user and never creates its
# parent, so the directory has to exist before the forward: /run is a tmpfs, hence
# tmpfiles.d, and the dev user owns it because a root-owned 0755 parent refuses
# the bind with EACCES — which the generated config's LogLevel ERROR hides.
echo "==> Registering /run/tart for forwarded agent sockets..."
install -d -m 755 /etc/tmpfiles.d
cat > /etc/tmpfiles.d/tart-stacks.conf <<EOF
# tart-stacks — parent directory for the per-agent SSH sockets that
# tart-ssh-sync's RemoteForward lines bind. Recreated every boot (/run is tmpfs).
d /run/tart 0700 ${TARGET_USER} ${TARGET_USER} -
EOF
chmod 644 /etc/tmpfiles.d/tart-stacks.conf
# Applied now as well as at every boot: it proves the line parses while the build
# can still fail, rather than at some clone's first multi-agent login.
systemd-tmpfiles --create /etc/tmpfiles.d/tart-stacks.conf

echo "==> user-config.sh complete."
