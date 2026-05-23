#!/usr/bin/env bash
# 00-base.sh — System updates, core dev packages, zellij, build toolchain.
# Runs as root via sudo from Packer. Stack-agnostic; every stack runs this
# before its own 00-stack.sh.

set -euo pipefail

echo "==> Updating system packages..."
dnf upgrade -y --refresh

echo "==> Installing core development packages (fail-loud)..."
# ncurses provides `tic` for the tssh wrapper's terminfo install path.
# gcc/gcc-c++/make listed explicitly — development-tools group composition
# drifts between Fedora releases; declaring deps here avoids silent breakage.
dnf install -y \
  curl wget ca-certificates \
  git gh \
  zsh nano \
  unzip tar \
  ncurses \
  gcc gcc-c++ make

echo "==> Installing diagnostics + quality-of-life tools (tolerate missing)..."
dnf install -y --skip-unavailable \
  htop lsof bind-utils nmap-ncat \
  jq \
  mariadb \
  ShellCheck \
  ripgrep fd-find fzf bat git-delta

# Build toolchain group. dnf5 prefers `group install` over `@` shorthand
# inside a mixed-package transaction (stricter about display-name vs ID).
dnf group install -y development-tools

# zellij isn't in Fedora's default repos; varlad/zellij is the canonical COPR.
# Override via `ZELLIJ_COPR=other/repo make build` if needed.
ZELLIJ_COPR="${ZELLIJ_COPR:-varlad/zellij}"
echo "==> Enabling COPR ${ZELLIJ_COPR} for zellij..."
dnf copr enable -y "${ZELLIJ_COPR}"
dnf install -y zellij

echo "==> Verifying baseline tooling..."
git --version
zsh --version
zellij --version

echo "==> 00-base.sh complete."
