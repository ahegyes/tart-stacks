#!/usr/bin/env bash
# mise.sh — Install mise system-wide from the jdxcode/mise COPR. Runs as root in
# the system provisioner block (dnf needs it); tool versions install later via
# mise-install.sh, after mise.toml is uploaded.

set -euo pipefail

echo "==> Installing mise (COPR jdxcode/mise)..."
# Add the COPR repo via its repo file (`dnf config-manager addrepo`) — `dnf copr
# enable` flaked writing the repo file mid-build. gpgcheck=1 keeps it signature-verified.
dnf install -y dnf-plugins-core
fedver="$(rpm -E %fedora)"
dnf config-manager addrepo --from-repofile="https://copr.fedorainfracloud.org/coprs/jdxcode/mise/repo/fedora-${fedver}/jdxcode-mise-fedora-${fedver}.repo"
dnf install -y mise
mise --version

# Create the target user's ~/.config/mise/ (owned by them, since we run as root)
# so the next Packer file provisioner can upload files/mise.toml into it.
install -d -o "${SUDO_USER:-admin}" -g "${SUDO_USER:-admin}" "/home/${SUDO_USER:-admin}/.config/mise"

echo "==> mise.sh complete."
