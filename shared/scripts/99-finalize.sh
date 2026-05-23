#!/usr/bin/env bash
# 99-finalize.sh — Establish the final SSH access posture and lock the admin password.
#
# Runs LAST. Before this script:
#   - Packer is connected via Cirrus's publicly-known admin/admin password.
#   - sshd accepts password auth (Cirrus default).
#   - No SSH key is authorized for admin.
#
# This script handles end-of-build operations that must run after every other
# provisioner:
#   - Clean dnf cache (free image size before state is locked).
#   - Authorize the user's SSH key (uploaded earlier to /tmp/authorized_key.pub).
#   - Install NOPASSWD sudoers drop-in for admin.
#   - Write sshd drop-in disabling password auth.
#   - Lock admin's password (passwd -l).
#
# Bundling makes the constraint "no provisioner can run between disabling
# password auth and Packer disconnecting" structural rather than documented —
# pkr.hcl ordering cannot violate it. The sshd drop-in and `passwd -l` land
# at the end to close the window between disabling password auth and
# disconnect to ~milliseconds.
#
# Runs as root via sudo from Packer.

set -euo pipefail

TARGET_USER="${SUDO_USER:-admin}"
TARGET_HOME="/home/${TARGET_USER}"
SUDOERS_FILE="/etc/sudoers.d/${TARGET_USER}-nopasswd"

# Clean dnf cache before locking down the image. ~200-300 MB of RPMs +
# metadata + solver cache in /var/cache/libdnf5/ would otherwise ship in
# every tart clone. Runs in finalize (not in the last dnf script) so any
# future dnf operations anywhere in the build get cleaned automatically.
echo "==> Cleaning dnf cache..."
dnf clean all

# Authorize the user's SSH key.
if [ ! -f /tmp/authorized_key.pub ]; then
  echo "ERROR: /tmp/authorized_key.pub not found. Did the Packer file provisioner run?" >&2
  exit 1
fi
# Parse-check before the irreversible passwd -l below — bad upload = no way in.
if ! ssh-keygen -l -f /tmp/authorized_key.pub >/dev/null 2>&1; then
  echo "ERROR: /tmp/authorized_key.pub is not a valid SSH public key. Refusing to proceed (would lock out ${TARGET_USER})." >&2
  exit 1
fi
echo "==> Authorizing user SSH key for ${TARGET_USER}..."
install -d -m 700 -o "${TARGET_USER}" -g "${TARGET_USER}" "${TARGET_HOME}/.ssh"
install -m 600 -o "${TARGET_USER}" -g "${TARGET_USER}" \
  /tmp/authorized_key.pub "${TARGET_HOME}/.ssh/authorized_keys"
rm -f /tmp/authorized_key.pub

# NOPASSWD sudoers — validated before landing on disk to avoid lockout
# on a broken file (a malformed sudoers can block this script's own sudo).
echo "==> Installing NOPASSWD sudoers drop-in for ${TARGET_USER}..."
TMP=$(mktemp)
trap 'rm -f "$TMP"' EXIT
cat > "$TMP" <<EOF
${TARGET_USER} ALL=(ALL) NOPASSWD: ALL
EOF
visudo -cf "$TMP"
install -m 440 -o root -g root "$TMP" "${SUDOERS_FILE}"

# sshd drop-in disabling password auth. Drop-in only takes effect on next
# sshd start (first boot of any clone) — sshd is intentionally not restarted
# here, so Packer's existing session continues working through the passwd -l
# below. The 00- prefix wins over cloud-init's 50-cloud-init.conf via
# "first occurrence wins" + Fedora's top-of-file Include directive.
echo "==> Writing sshd drop-in to disable password auth..."
install -m 600 -o root -g root /dev/stdin /etc/ssh/sshd_config.d/00-vm-hardening.conf <<'EOF'
# tart-stacks hardening — applies on next sshd start.
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
PermitRootLogin no

# Required for any RemoteForward of a Unix domain socket (e.g. forwarding a
# host SSH agent socket into the VM): lets sshd unlink and recreate the
# socket on each session instead of failing if a stale one exists.
StreamLocalBindUnlink yes
EOF
sshd -t

# Lock admin's password. After this, SSH key auth is the only way in.
# Packer disconnects immediately after this script returns.
echo "==> Locking ${TARGET_USER} password (SSH key auth is the only access path now)..."
passwd -l "${TARGET_USER}"

echo "==> 99-finalize.sh complete. Key authorized, NOPASSWD sudo, password auth disabled, password locked."
