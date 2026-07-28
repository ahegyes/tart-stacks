#!/usr/bin/env bash
# 00-stack.sh — install this stack's build dependencies from packages.<family>
# (uploaded to /tmp). OS variance lives in those data files, not here. A missing
# package drops the capability it provides — family-lib.sh warns and records it in
# the image manifest — so the stack's smoke test (in mise-install.sh) is the backstop.
# Runs as root immediately after the platform's own 00-base.sh: shared/linux/scripts/
# on linux, shared/darwin/scripts/ on darwin. This file is shared by both.
# Per-stack on purpose — the slot for any imperative build-prep beyond the
# packages.<family> list; identical across stacks until one needs more.
set -euo pipefail
# shellcheck source=/dev/null
source /tmp/family-lib.sh
list="/tmp/packages.${_TART_FAMILY}"
# grep exits 1 when the list is all-comments/empty; tolerate it (the empty case is
# valid — a stack with no native deps) so set -e doesn't abort here.
pkgs="$(grep -vE '^[[:space:]]*(#|$)' "$list" 2>/dev/null | tr '\n' ' ' || true)"
if [ -n "$pkgs" ]; then
  echo "==> Installing $(basename "$list") packages..."
  # shellcheck disable=SC2086  # intentional word-split of the package list
  pkg_install_optional $pkgs
else
  echo "==> No packages in $(basename "$list") — skipping."
fi
echo "==> 00-stack.sh complete."
