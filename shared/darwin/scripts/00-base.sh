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
# not — and every clone would inherit the lie. The guest being Darwin at all is
# already asserted above, at the source line: family-lib.sh's _detect_family
# hard-exits before returning control here if uname -s isn't Darwin, so the only
# mislabeling this build can still commit is a wrong OS token.
echo "==> Verifying the guest is the os this build claims (${OS:-unset})..."
if [ "${OS:-}" != "macos" ]; then
  echo "ERROR: this darwin-platform provisioner expects OS=macos, but found OS='${OS:-unset}'. Refusing to mislabel the image." >&2
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

# Pre-create ~/.config/mise/ for the mise.toml upload later in this build:
# Packer's file provisioner does not create intermediate destination
# directories, and this script is where that upload's directory belongs —
# the linux peer does the equivalent inside mise.sh, its own mise-owning
# script; darwin has no mise.sh (see above), so this is that script here.
# Owned by TART_BUILD_USER (family-lib.sh), not root: this runs as root via
# sudo, but the later unprivileged mise-install.sh must be able to write
# inside it. `staff`, not a user-private group — macOS has no per-user group
# the way linux does.
echo "==> Pre-creating ~/.config/mise/ for the mise.toml upload..."
install -d -o "$TART_BUILD_USER" -g staff "/Users/${TART_BUILD_USER}/.config/mise"

echo "==> Installing core tooling..."
# zellij has no macOS package peer (installed here since darwin skips
# shared/linux/scripts/mise.sh, the linux platform's zellij owner). wget and gh
# are both in the linux platform's core set (shared/linux/scripts/00-base.sh's
# `core=`) but absent from a base macOS install — curl, git, nano, unzip, tar,
# and a C toolchain all ship with the Cirrus base already; wget and gh do not.
pkg_install zellij jq wget gh

echo "==> Installing diagnostics + quality-of-life tools (tolerate missing)..."
# Mirrors the linux platform's qol set (shared/linux/scripts/00-base.sh) minus
# what macOS already ships as part of the base system rather than a package:
# lsof (/usr/sbin/lsof), nc (/usr/bin/nc — linux's nmap-ncat/netcat-openbsd),
# and dig (/usr/bin/dig — linux's bind-utils/bind9-dnsutils) are all OS-shipped,
# not under /opt/homebrew; installing a formula for any of them would
# re-assert what the platform already owns. jq is already installed above.
#
# mysql-client, not mariadb: linux ships the CLIENT only (dnf's mariadb is
# Fedora's client package; apt's mariadb-client is explicit), but brew's
# mariadb formula is the full server, and mariadb-client is not a Homebrew
# formula at all. mysql-client is the intent-preserving match — the CLI tools
# without a server. It is keg-only (brew will not symlink it into
# /opt/homebrew because it conflicts with mysql's client libraries), so its
# bin/ is not on PATH by default the way the rest of this list is.
pkg_install_optional htop mysql-client shellcheck ripgrep fd fzf bat git-delta

echo "==> 00-base.sh complete."
