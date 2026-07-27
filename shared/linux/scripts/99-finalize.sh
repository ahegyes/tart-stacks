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
#   - Assert mandatory access control is still active (a regressed base fails the build here).
#   - Clean the package cache (free image size before state is locked).
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
# shellcheck source=/dev/null
source /tmp/family-lib.sh

TARGET_USER="${SUDO_USER:-admin}"
TARGET_HOME="/home/${TARGET_USER}"
SUDOERS_FILE="/etc/sudoers.d/${TARGET_USER}-nopasswd"

# Assert the inherited mandatory-access-control posture survived the build. The base
# ships it active and nothing here touches it, so this is free today — but asserting it
# at the end turns an inherited property into a guaranteed one: a future base that
# silently shipped MAC disabled (or a stray provisioner that flipped it) fails the build
# here instead of minting a downgraded image every clone would inherit.
echo "==> Verifying mandatory access control is active..."
assert_mac_enforcing || exit 1

# Clean the package cache before locking down the image — cached packages + metadata
# (hundreds of MB) would otherwise ship in every clone. Runs in finalize so any package
# operation anywhere in the build gets cleaned automatically.
echo "==> Cleaning package cache..."
pkg_clean

# Provenance manifest: the build floats its inputs (latest base image, lts/
# latest tools), so record what they RESOLVED to — "what is this image
# carrying?" must be answerable from a clone without booting and inspecting
# tool-by-tool. Staged fragments: /tmp/tart-stacks-tools (mise-install) and
# /tmp/tart-stacks-skipped (family-lib's optional-install skips). STACK/OS
# arrive as environment_vars from the Packer template.
echo "==> Writing /etc/tart-stacks-release..."
{
  echo "built: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  echo "stack: ${STACK:-unknown}"
  echo "os: ${OS:-unknown}"
  # gui: <de> | none — the machine-readable "is this a GUI flavor" answer
  # (shared/linux/gui/README.md documents what a `gui: <de>` image exposes).
  if [ "${GUI:-false}" = "true" ]; then echo "gui: ${DE:-unknown}"; else echo "gui: none"; fi
  # support-end: <date> | none — the same field 00-base.sh's release gate reads, so
  # a clone can be judged stale from the manifest alone. `none` is the honest answer
  # for the apt family, which publishes no equivalent, not a claim of endless support.
  # shellcheck disable=SC1091  # guest-only file, absent at lint time
  ( . /etc/os-release 2>/dev/null || true
    echo "os: ${PRETTY_NAME:-unknown} (${VERSION_ID:-?})"
    echo "support-end: ${SUPPORT_END:-none}" )
  # agent: <version> — the daemon serving `tart exec`. Recorded because the build
  # installs it rather than inheriting it, so a clone can be checked against the
  # pin without booting it and asking. Read from the binary, not the package
  # database, so it reports what would actually answer the host.
  agent_ver="$(tart-guest-agent --version 2>/dev/null | awk '{print $NF}')"
  echo "agent: ${agent_ver:-unknown}"
  echo ""
  if [ -f /tmp/tart-stacks-tools ]; then
    echo "tools:"
    cat /tmp/tart-stacks-tools
    echo ""
  fi
  if [ -s /tmp/tart-stacks-skipped ]; then
    echo "skipped-optional-packages:"
    sort -u /tmp/tart-stacks-skipped
  else
    echo "skipped-optional-packages: none recorded"
  fi
} > /etc/tart-stacks-release
chmod 644 /etc/tart-stacks-release
rm -f /tmp/tart-stacks-tools /tmp/tart-stacks-skipped

# Authorize the user's SSH key.
if [ ! -f /tmp/authorized_key.pub ]; then
  echo "ERROR: /tmp/authorized_key.pub not found. Did the Packer file provisioner run?" >&2
  exit 1
fi
# The private half needs its own gate ahead of the parse check: `ssh-keygen -l
# -f` prints a fingerprint and exits 0 for a private key too — plain,
# passphrase-protected, PEM and PKCS8 alike — so the parse check cannot see it.
# Authorizing one bakes a private key into every clone and authenticates nobody,
# which the irreversible passwd -l below then makes unrecoverable. The whole PEM
# armor is required, but not at the start of a line: a public key's comment field
# is free text, so the bare words would abort a build over a comment reading
# "PRIVATE KEY" — while a line anchor would miss an indented private block pasted
# below a valid pubkey line, which the parse check below accepts.
if grep -q -- '-----BEGIN .*PRIVATE KEY-----' /tmp/authorized_key.pub; then
  echo "ERROR: /tmp/authorized_key.pub holds a PRIVATE key. Refusing to proceed (it would authorize no one and ship the private half in every clone) — point var.ssh_pubkey_path at the .pub half." >&2
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
# "first occurrence wins" + OpenSSH's top-of-file Include directive.
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
# sshd -t needs the privilege-separation dir to exist; it's created at service start,
# so it's absent mid-build on apt-family images (present on dnf). Create it idempotently.
mkdir -p /run/sshd
sshd -t

# Lock admin's password. After this, SSH key auth is the only way in.
# Packer disconnects immediately after this script returns.
echo "==> Locking ${TARGET_USER} password (SSH key auth is the only access path now)..."
passwd -l "${TARGET_USER}"

echo "==> 99-finalize.sh complete. Key authorized, NOPASSWD sudo, password auth disabled, password locked."
