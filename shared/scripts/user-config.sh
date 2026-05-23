#!/usr/bin/env bash
# user-config.sh — Set zsh as default shell and finalize PATH activation.
# Runs as root via sudo (chsh requires it for another user's account).

set -euo pipefail

TARGET_USER="${SUDO_USER:-admin}"
TARGET_HOME="/home/${TARGET_USER}"

echo "==> Setting zsh as default shell for ${TARGET_USER}..."
chsh -s /usr/bin/zsh "${TARGET_USER}"

# Activate mise in bash too — so non-zsh sessions (`docker exec`, scripts,
# manual `bash` invocations) still get per-directory tool version switching.
BASHRC="${TARGET_HOME}/.bashrc"
if [ ! -f "${BASHRC}" ] || ! grep -q "mise activate" "${BASHRC}"; then
  cat >> "${BASHRC}" <<'EOF'
# mise activation — added by fedora-php-tart provisioning.
[ -x "$HOME/.local/bin/mise" ] && eval "$($HOME/.local/bin/mise activate bash)"
EOF
  chown "${TARGET_USER}:${TARGET_USER}" "${BASHRC}"
fi

# Ensure ~/.local/bin is on PATH for every zsh session. .zshenv loads before
# .zshrc and runs for both interactive and non-interactive shells (so PATH is
# set even when Claude Code, mise, or another tool spawns a non-interactive zsh).
ZSHENV="${TARGET_HOME}/.zshenv"
if [ ! -f "${ZSHENV}" ] || ! grep -q "HOME/.local/bin" "${ZSHENV}"; then
  cat >> "${ZSHENV}" <<'EOF'
# Added by fedora-php-tart provisioning — ensures user-local binaries are on PATH.
export PATH="$HOME/.local/bin:$PATH"
EOF
  chown "${TARGET_USER}:${TARGET_USER}" "${ZSHENV}"
fi

# Verify provisioned config files are owned by the target user.
chown "${TARGET_USER}:${TARGET_USER}" "${TARGET_HOME}/.zshrc"
chown -R "${TARGET_USER}:${TARGET_USER}" "${TARGET_HOME}/.config"

echo "==> user-config.sh complete."
