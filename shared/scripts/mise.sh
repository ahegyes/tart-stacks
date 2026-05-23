#!/usr/bin/env bash
# mise.sh — Install mise binary (per-user, ~/.local/bin/mise).
# Tool versions are installed later by mise-install.sh, after mise.toml is uploaded.

set -euo pipefail

echo "==> Installing mise..."
curl -fsSL --retry 3 --retry-delay 2 https://mise.run | sh

export PATH="$HOME/.local/bin:$PATH"
mise --version

# Ensure ~/.config/mise/ exists for the Packer file provisioner that uploads
# files/mise.toml in the next step (file provisioner does not create parent dirs).
mkdir -p "$HOME/.config/mise"

echo "==> mise.sh complete."
