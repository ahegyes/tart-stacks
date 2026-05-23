#!/usr/bin/env bash
# claude.sh — Install Claude Code via Anthropic's native installer.
# Runs as the unprivileged SSH user (not root).
#
# The native installer is a single self-contained binary placed in ~/.local/bin/claude.
# It auto-updates in the background (configurable via `autoUpdatesChannel` in settings).
# Authentication happens on first interactive use; provisioning does not require it.

set -euo pipefail

echo "==> Installing Claude Code (native installer)..."
curl -fsSL --retry 3 --retry-delay 2 https://claude.ai/install.sh | bash

export PATH="$HOME/.local/bin:$PATH"

if ! command -v claude >/dev/null 2>&1; then
  echo "ERROR: Claude binary not found at $HOME/.local/bin/claude" >&2
  exit 1
fi
echo "==> Verifying Claude Code install..."
claude --version

echo "==> claude.sh complete. First run will prompt for authentication."
