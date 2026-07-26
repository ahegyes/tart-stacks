#!/usr/bin/env bash
# mise-install.sh (Foo) — install the runtimes declared in files/mise.toml
# (uploaded to ~/.config/mise/config.toml) as the unprivileged build user, then
# HARD-GATE the build on a smoke test so a missing tool fails the build instead of
# shipping a broken image. The shared mechanism (install/activate, smoke loop) is in
# /tmp/mise-lib.sh, uploaded by the Packer template; add the Foo payload here.

set -euo pipefail
# /tmp/mise-lib.sh is staged on the guest by the Packer template (absent at lint time).
# shellcheck source=/dev/null
source /tmp/mise-lib.sh

mise_runtime_setup

# Smoke test (hard gate): one `--`-delimited command per tool declared in
# files/mise.toml — argv tokens, not a quoted string.
smoke_gate "Foo runtimes" \
  -- node --version

echo "==> mise-install.sh (Foo) complete."
