#!/usr/bin/env bash
# docker.sh — Install Docker CE from Docker's official Fedora repository.
# Runs as root via sudo from Packer.
#
# Why Docker CE and not Fedora's `moby-engine` package: Fedora's package is
# the open-source Moby project with podman-docker compatibility shims layered
# in by the distro. Docker CE is the genuine Docker daemon — same binaries,
# same release cadence, same `docker compose` plugin behavior as the
# macOS/Windows Desktop installs.

set -euo pipefail

# Require dnf5 — `config-manager addrepo --from-repofile=` is dnf5-only syntax.
DNF_MAJOR=$(dnf --version 2>&1 | head -1 | grep -oE '^[0-9]+')
[ "${DNF_MAJOR:-0}" -ge 5 ] || { echo "docker.sh requires dnf5 (Fedora 41+); detected dnf major: ${DNF_MAJOR:-unknown}" >&2; exit 1; }

echo "==> Setting up Docker's Fedora repository..."
dnf -y install dnf-plugins-core
dnf config-manager addrepo --from-repofile=https://download.docker.com/linux/fedora/docker-ce.repo

echo "==> Installing Docker CE..."
dnf install -y \
  docker-ce \
  docker-ce-cli \
  containerd.io \
  docker-buildx-plugin \
  docker-compose-plugin

echo "==> Enabling Docker service..."
systemctl enable --now docker

TARGET_USER="${SUDO_USER:-admin}"

echo "==> Adding ${TARGET_USER} to the docker group..."
usermod -aG docker "${TARGET_USER}"
# NOTE: group membership applies on NEXT login. Any later provisioner that
# needs docker access from this user must `sg docker -c '<cmd>'` or
# explicitly re-login. No current scripts need this.

echo "==> Verifying Docker..."
docker --version
docker compose version

echo "==> docker.sh complete. Group membership applies on next login."
