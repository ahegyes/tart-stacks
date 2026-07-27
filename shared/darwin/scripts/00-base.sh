#!/usr/bin/env bash
# 00-base.sh (darwin) — first provisioner. Asserts the guest is the os this build
# claims, that its release is not older than the pin, and that the guest agent is
# whole; then brings brew and the core toolchain up to date.
#
# Runs as root via sudo from Packer. Package work goes through family-lib.sh,
# which drops privileges — brew refuses to run as root.
set -euo pipefail
# shellcheck source=/dev/null
source /tmp/family-lib.sh

# The image name and the provenance manifest are both written from OS, so a build
# that landed on the wrong base would ship an image mislabeled as something it is
# not — and every clone would inherit the lie.
echo "==> Verifying the guest is the os this build claims (${OS:-unset})..."
guest_os="$(uname -s)"
if [ "$guest_os" != "Darwin" ] || [ "${OS:-}" != "macos" ]; then
  echo "ERROR: this darwin-platform provisioner expects a Darwin guest with OS=macos, but found guest kernel='${guest_os}' and OS='${OS:-unset}'. Refusing to mislabel the image." >&2
  exit 1
fi

echo "==> Verifying the release is not older than the pin..."
assert_release_supported || exit 1

# tart exec is a host->guest vsock call served by the guest agent, and nothing
# here installs it. An image missing it builds clean, then leaves every clone on
# the base image's hostname with no signal until something reads it.
echo "==> Verifying the guest agent is whole..."
install_guest_agent || exit 1

echo "==> Updating Homebrew..."
pkg_refresh

# mise ships in the Cirrus macOS base, unlike the linux images where a repo has
# to be added first — hence no mise.sh peer on this platform. Installed here only
# if a future base drops it, so the stack's mise-install.sh always has it.
if ! command -v mise >/dev/null 2>&1; then
  echo "==> mise absent from this base; installing..."
  pkg_install mise
fi

echo "==> Installing core tooling..."
pkg_install zellij jq

echo "==> 00-base.sh complete."
