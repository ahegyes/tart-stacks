#!/usr/bin/env bash
# 00-base.sh — system update, core dev packages, zellij, build toolchain. Runs as
# root; stack-agnostic, distro-agnostic via distro-lib.sh. Every stack runs this
# before its own 00-stack.sh.
set -euo pipefail
# shellcheck source=/dev/null
source /tmp/distro-lib.sh

echo "==> Updating system packages..."
pkg_refresh

# gh ships in dnf base repos but needs an added repo on apt (repo_add_github_cli);
# ncurses terminfo for common terminals is in the core set so interactive ssh renders
# right without per-connect terminfo push.
echo "==> Installing core development packages (fail-loud)..."
repo_add_github_cli
case "$_DISTRO_FAMILY" in
  dnf) core="curl wget ca-certificates git gh zsh nano unzip tar ncurses ncurses-term gcc gcc-c++ make" ;;
  apt) core="curl wget ca-certificates git gh zsh nano unzip tar ncurses-base ncurses-bin g++ gcc make gnupg" ;;
esac
# shellcheck disable=SC2086  # intentional word-split of the package list
pkg_install $core

echo "==> Installing diagnostics + quality-of-life tools (tolerate missing)..."
case "$_DISTRO_FAMILY" in
  dnf) qol="htop lsof bind-utils nmap-ncat jq mariadb ShellCheck ripgrep fd-find fzf bat git-delta" ;;
  apt) qol="htop lsof dnsutils netcat-openbsd jq mariadb-client shellcheck ripgrep fd-find fzf bat git-delta" ;;
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
