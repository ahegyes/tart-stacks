#!/usr/bin/env bash
# 00-base.sh — system update, core dev packages, zellij, build toolchain. Runs as
# root; stack-agnostic, distro-agnostic via distro-lib.sh. Every stack runs this
# before its own 00-stack.sh.
set -euo pipefail
# shellcheck source=/dev/null
source /tmp/distro-lib.sh

# Assert the guest is the distro this build calls itself, first thing. The image
# name and the provenance manifest are both written from the build's own DISTRO,
# never from the guest — so a build that started from the wrong base would
# succeed and ship mislabeled, and every clone would inherit the lie. Failing
# here costs a minute; failing at 99-finalize would cost the whole build.
# shellcheck disable=SC1091  # guest-only file, absent at lint time
guest_id="$( . /etc/os-release 2>/dev/null && printf '%s' "${ID:-}" )"
if [ -n "${DISTRO:-}" ] && [ "$guest_id" != "$DISTRO" ]; then
  echo "ERROR: this build declares DISTRO=$DISTRO but the guest reports ID=${guest_id:-unknown}." >&2
  echo "       The image name and /etc/tart-stacks-release both come from DISTRO, so continuing" >&2
  echo "       would ship a mislabeled image. Re-run 'make bootstrap DISTRO=$DISTRO' first." >&2
  exit 1
fi

# The other thing inherited from the base rather than built here: the agent that
# serves `tart exec`. That is a host->guest vsock RPC, NOT ssh — and ssh is all
# Packer and the toolchain checks ever use, so a base without the agent produces
# an image that builds clean, smokes its toolchain clean, and then fails the
# first time tart-up sets a guest hostname or activates a desktop (a hard exit
# for --gui). Nothing downstream of here would notice, so check the substrate
# while it still costs a minute. Enabled, not merely installed: a clone's first
# boot is where it has to come up.
if ! command -v tart-guest-agent >/dev/null 2>&1 ||
   ! systemctl is-enabled --quiet tart-guest-agent.service 2>/dev/null; then
  echo "ERROR: this base image has no enabled tart-guest-agent.service." >&2
  echo "       'tart exec' is a host->guest vsock call served by that agent inside the guest;" >&2
  echo "       the host's own tart install cannot supply it. Without it, tart-up cannot set a" >&2
  echo "       clone's hostname and every GUI activation fails, yet this build would succeed." >&2
  echo "       Install tart-guest-agent in the base image before building a stack on it." >&2
  exit 1
fi

echo "==> Updating system packages..."
pkg_refresh

# gh ships in dnf base repos but needs an added repo on apt (repo_add_github_cli);
# ncurses terminfo for common terminals is in the core set so interactive ssh renders
# right without per-connect terminfo push.
echo "==> Installing core development packages (fail-loud)..."
repo_add_github_cli
case "$_DISTRO_FAMILY" in
  dnf) core="curl wget ca-certificates git gh zsh nano unzip tar ncurses ncurses-term gcc gcc-c++ make" ;;
  apt) core="curl wget ca-certificates git gh zsh nano unzip tar ncurses-base ncurses-bin ncurses-term g++ gcc make gnupg" ;;
esac
# shellcheck disable=SC2086  # intentional word-split of the package list
pkg_install $core

echo "==> Installing diagnostics + quality-of-life tools (tolerate missing)..."
case "$_DISTRO_FAMILY" in
  dnf) qol="htop lsof bind-utils nmap-ncat jq mariadb ShellCheck ripgrep fd-find fzf bat git-delta" ;;
  apt) qol="htop lsof bind9-dnsutils netcat-openbsd jq mariadb-client shellcheck ripgrep fd-find fzf bat git-delta" ;;
esac
# shellcheck disable=SC2086
pkg_install_optional $qol

echo "==> Installing build toolchain group..."
pkg_group_devtools

echo "==> Installing zellij..."
install_zellij

echo "==> Verifying baseline tooling..."
git --version
zsh --version
zellij --version

echo "==> 00-base.sh complete."
