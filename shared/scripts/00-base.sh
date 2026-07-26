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
# this build ever speaks, so a base whose agent does not work builds clean and
# then leaves every clone on the base image's hostname (tart-up only warns) and
# hard-fails any GUI activation. Two failing states with two different fixes, so
# they are reported apart.
#
# The literal string `enabled` is the test rather than is-enabled's exit status,
# which is also 0 for `static` and `enabled-runtime` — neither of which survives
# into a clone's first boot, the only boot that matters for an image.
agent_state=$(systemctl is-enabled tart-guest-agent.service 2>/dev/null || true)
if [ "$agent_state" != enabled ]; then
  echo "ERROR: this base image has no enabled tart-guest-agent.service (systemctl reports" >&2
  echo "       '${agent_state:-not-found}'). 'tart exec' is a host->guest vsock call served by that agent" >&2
  echo "       inside the guest; the host's own tart install cannot supply it. Install and enable" >&2
  echo "       it in the base image, then re-run 'make bootstrap DISTRO=${DISTRO:-<distro>}'." >&2
  exit 1
fi
# Enabled only promises systemd will try to start it. An agent that dies during
# startup in this guest dies the same way on every clone of the image.
if ! systemctl is-active --quiet tart-guest-agent.service; then
  echo "ERROR: tart-guest-agent.service is enabled but not running in this guest." >&2
  echo "       It answers the host's 'tart exec' calls over vsock, so tart-up cannot set a" >&2
  echo "       clone's hostname and no GUI mode can start. Inspect 'systemctl status" >&2
  echo "       tart-guest-agent' and its journal in the base image." >&2
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
