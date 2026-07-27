#!/usr/bin/env bash
# mise.sh — install mise system-wide via the family's signed repo. Tool versions
# install later via mise-install.sh, after mise.toml is uploaded. Runs as root.
set -euo pipefail
# shellcheck source=/dev/null
source /tmp/family-lib.sh

echo "==> Installing mise..."
repo_add_mise
# Verify with HOME=/root so root's mise can't seed the build user's ~/.cache: sudo's
# HOME handling varies by distro (apt preserves /home/<user>, dnf resets to /root), and a
# root-owned ~/.cache would block the later unprivileged `mise install`.
HOME=/root mise --version

# Pre-create the build user's ~/.config/mise/ (for the uploaded config.toml) and make
# sure they own ~/.cache, so the unprivileged mise-install.sh can populate both.
u="${SUDO_USER:-admin}"
install -d -o "$u" -g "$u" "/home/$u/.config/mise"
mkdir -p "/home/$u/.cache"
chown -R "$u:$u" "/home/$u/.cache"

echo "==> mise.sh complete."
