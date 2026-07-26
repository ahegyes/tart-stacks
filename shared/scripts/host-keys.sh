#!/usr/bin/env bash
# host-keys.sh — install a first-boot oneshot that gives every clone its own
# SSH host keys. Clones inherit the base image's baked-in keys, which makes
# host-key pinning theater; regenerating BEFORE sshd's first start means the
# first connection a clone ever serves already presents its own key — no
# restart step, no marker-ordering hazard, no host→guest vsock call.
#
# This is the only regeneration path — nothing on the host repeats it. The image
# must ship WITHOUT the marker (/etc/ssh/.tart-keys) so each clone's first boot
# triggers the unit; the build VM never reboots after provisioning, so the unit
# cannot fire during the build. Runs as root via sudo from Packer.
set -euo pipefail

echo "==> Installing first-boot host-key regeneration..."

# The regen lives in a plain script (not inline in ExecStart) so it stays
# lintable and clear of systemd's $-escaping rules.
cat > /usr/local/sbin/tart-stacks-host-keys <<'EOF'
#!/bin/sh
# Regenerate this machine's SSH host keys once (a tart-stacks clone's first
# boot). Stage to .new then swap, so /etc/ssh never holds a half-written set.
set -e
cd /etc/ssh
# Staging left by an interrupted run would make ssh-keygen prompt to
# overwrite — and die on the unit's /dev/null stdin — so clear it first.
rm -f ssh_host_*_key.new ssh_host_*_key.new.pub
for t in rsa ecdsa ed25519; do
  ssh-keygen -q -N "" -t "$t" -f "ssh_host_${t}_key.new"
done
for t in rsa ecdsa ed25519; do
  mv -f "ssh_host_${t}_key.new" "ssh_host_${t}_key"
  mv -f "ssh_host_${t}_key.new.pub" "ssh_host_${t}_key.pub"
done
touch /etc/ssh/.tart-keys
EOF
chmod 755 /usr/local/sbin/tart-stacks-host-keys

cat > /etc/systemd/system/tart-stacks-host-keys.service <<'EOF'
[Unit]
Description=Regenerate SSH host keys on a clone's first boot (tart-stacks)
# Every name the daemon answers to, across families and activation styles:
# dnf ships sshd.service, apt ships ssh.service, and apt also socket-activates
# through ssh.socket. systemd ignores ordering against units that do not exist.
Before=ssh.service sshd.service ssh.socket
ConditionPathExists=!/etc/ssh/.tart-keys

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/tart-stacks-host-keys

[Install]
WantedBy=multi-user.target
EOF

systemctl enable tart-stacks-host-keys.service

# A freshly provisioned base must not carry the marker: the build's own boot
# predates this unit, and a leftover marker would skip every clone's regen.
rm -f /etc/ssh/.tart-keys

echo "==> host-keys.sh complete."
