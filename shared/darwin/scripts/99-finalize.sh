#!/usr/bin/env bash
# 99-finalize.sh (darwin) — Establish the final access posture: close the
# base's remote-access surface, authorize the build's SSH key, and record
# provenance. Runs LAST.
#
# Before this script:
#   - Packer is connected via Cirrus's publicly-known admin/admin password.
#   - The base ships Screen Sharing (*:5900) and a Kerberos KDC (*:88)
#     listening on every interface, both reachable with that same password.
#   - sshd accepts password auth (Cirrus default).
#   - No SSH key is authorized for admin.
#
# Unlike the linux peer, this script never locks the account password (see
# the `password:` manifest line below for why) and never installs its own
# NOPASSWD sudoers drop-in — the base ships one already, so this script
# asserts it rather than reinstalling it (the same contract
# install_guest_agent uses). So the "shrink the window between disabling
# password auth and Packer disconnecting" pressure that shapes the linux
# script's bundling does not apply here in the same way — the surface this
# script closes is the listening services and SSH password auth, not the
# console account itself.
#
# Runs as root via sudo from Packer.

set -euo pipefail
# shellcheck source=/dev/null
source /tmp/family-lib.sh
# shellcheck source=/dev/null
source /tmp/authorized-key-lib.sh

# Overridable root prefix, empty in production — the same seam
# shared/darwin/scripts/user-config.sh established (TART_ROOT), applied here
# to every filesystem path below so this script is testable against a
# synthetic tree instead of the real one. launchctl and netstat take no path
# to prefix — a service label and a system-wide port scan, not files — so
# both are PATH-mocked in the test instead.
TART_ROOT="${TART_ROOT:-}"

TARGET_USER="${SUDO_USER:-admin}"
TARGET_HOME="${TART_ROOT}/Users/${TARGET_USER}"

# Re-verify the sealed-system-volume posture family-lib.sh asserts survives
# the build, mirroring the linux peer's re-assert at this same position: free
# today since nothing here touches it, but asserting it at the end turns an
# inherited property into a guaranteed one instead of a silently regressed
# base shipping unnoticed.
echo "==> Verifying mandatory access control is active..."
assert_integrity_enforced || exit 1

echo "==> Cleaning package cache..."
pkg_clean

# The base leaves two remote-access services listening on every interface:
# Screen Sharing on *:5900 (it answers RFB 003.889) and a Kerberos KDC on
# *:88, both reachable with the publicly-known admin password. screensharingd
# cannot be rebound to loopback — measured: a launchd job with SockNodeName
# binds 127.0.0.1 but never serves, since it only answers from its own job on
# the sealed system volume — so switching it off is the only way to close it.
echo "==> Disabling the base's remote-access services..."
for svc in com.apple.screensharing com.apple.Kerberos.kdc; do
  launchctl disable "system/${svc}" || true
  launchctl bootout  "system/${svc}" 2>/dev/null || true
done

# The base is a CI image; a dev VM inherits Actions-runner install artifacts
# it will never use: ~/actions-runner (the build user's own runner checkout,
# a directory) and /Users/runner — measured: a SYMLINK to /Users/admin, not a
# second account's home directory, hence no trailing slash on the target
# below (one would make rm follow the link and recurse into the real home).
# rm -rf for both regardless of shape: `rm -f` on a directory fails outright
# under set -e, which would abort this, the LAST provisioner, mid-script.
echo "==> Removing CI runner artifacts not used by a dev VM..."
rm -rf "${TARGET_HOME}/actions-runner"
rm -rf "${TART_ROOT}/Users/runner"

# Part of the same final-posture sweep as the listener assert below: a
# non-interactive `ssh <vm> sudo ...` (which tart-up's escalation and any
# script/agent driving this VM depends on) hangs or fails without a working
# NOPASSWD rule, and an unlocked-but-unprompted console password (see
# password: below) does not by itself guarantee one.
echo "==> Verifying NOPASSWD sudo is in place..."
assert_nopasswd_sudo || exit 1

# The whole access posture of this image is "one listener, key-only", so it
# is asserted rather than documented. Runs after the services above are
# down, so it observes the surface this script actually produced.
echo "==> Verifying the listener surface is :22 alone..."
# Parsed once, into a variable, so a failing netstat aborts here under
# `set -euo pipefail` instead of being swallowed. Folding the read into the
# `|| true` below would make an unreadable table indistinguishable from a
# clean one.
listen_ports="$(netstat -an -p tcp | awk '$NF == "LISTEN" { n = split($4, a, "."); print a[n] }' | sort -u)"
# Must-pass control, the same one script/smoke's runtime peer applies: :22 has
# to appear in the parsed set on its own. Without it "nothing unexpected is
# listening" is vacuously true of an empty read or a parse that stopped
# matching — which is exactly how this assert would fail silently if a future
# macOS changed netstat's column shape.
if ! printf '%s\n' "$listen_ports" | grep -qx 22; then
  echo "ERROR: the listener table does not show :22 itself (got: $(printf '%s' "$listen_ports" | tr '\n' ' ')). sshd is serving this very build, so this read is not trustworthy evidence — refusing to certify the listener surface from it." >&2
  exit 1
fi
unexpected="$(printf '%s\n' "$listen_ports" | grep -vx 22 || true)"
if [ -n "$unexpected" ]; then
  echo "ERROR: unexpected listening port(s): $(echo "$unexpected" | tr '\n' ' ')— this image is supposed to expose ssh and nothing else." >&2
  exit 1
fi

# Provenance manifest, same contract as the linux peer's: record what this
# build's inputs resolved to. `os:` is the BUILD TOKEN, not a description —
# script/smoke counts `os:` lines and fails the smoke on anything but exactly
# one, since its field() reader takes the first match and silently orphans a
# second (the defect commit b617bdd fixed on linux). The descriptive string
# goes in `os-pretty:` instead.
echo "==> Writing ${TART_ROOT}/etc/tart-stacks-release..."
{
  echo "built: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  echo "stack: ${STACK:-unknown}"
  echo "os: ${OS:-unknown}"
  echo "platform: darwin"
  echo "os-pretty: $(sw_vers -productName) $(sw_vers -productVersion) ($(sw_vers -buildVersion))"
  # support-end: none — macOS publishes no end-of-life date this build can
  # read, unlike the linux peer's SUPPORT_END; `none` is the honest answer,
  # not a claim of endless support.
  echo "support-end: none"
  # Recorded, not asserted: SIP cannot be re-enabled from inside a running
  # system, and every Cirrus base ships it off. The sealed system volume is
  # the property that does hold, and assert_integrity_enforced above gates
  # the build on it.
  echo "sip: $(csrutil status 2>/dev/null | grep -o 'enabled\|disabled' | head -1)"
  echo "ssv: $(csrutil authenticated-root status 2>/dev/null | grep -o 'enabled\|disabled' | head -1)"
  # Deliberate divergence from the linux images, recorded so a reader does
  # not assume it was forgotten: auto-login must keep working for the GUI,
  # which makes the console session already-open at boot and a console
  # password meaningless, while a randomized one is unrecoverable — resetting
  # it needs the old one (SecureToken). Protection is the listener surface
  # asserted above, not the password.
  echo "password: unlocked (console-only; sshd is key-only)"
  # No agent: line — unlike the linux peer's pinned TART_GUEST_AGENT_VERSION,
  # nothing here installs or resolves a version for the guest agent
  # (install_guest_agent is assert-only on this platform), so there is no
  # build input to record.
  echo ""
  if [ -f "${TART_ROOT}/tmp/tart-stacks-tools" ]; then
    echo "tools:"
    cat "${TART_ROOT}/tmp/tart-stacks-tools"
    echo ""
  fi
  if [ -s "${TART_ROOT}/tmp/tart-stacks-skipped" ]; then
    echo "skipped-optional-packages:"
    sort -u "${TART_ROOT}/tmp/tart-stacks-skipped"
  else
    echo "skipped-optional-packages: none recorded"
  fi
} > "${TART_ROOT}/etc/tart-stacks-release"
chmod 644 "${TART_ROOT}/etc/tart-stacks-release"
rm -f "${TART_ROOT}/tmp/tart-stacks-tools" "${TART_ROOT}/tmp/tart-stacks-skipped"

# Authorize the user's SSH key. assert_authorized_key_safe (shared/scripts/
# authorized-key-lib.sh) is the gate — it must run before authorizing the key
# and before the sshd drop-in below disables password auth: a bad upload
# accepted here is no way back in once that lands.
assert_authorized_key_safe /tmp/authorized_key.pub || exit 1
echo "==> Authorizing user SSH key for ${TARGET_USER}..."
install -d -m 700 -o "${TARGET_USER}" -g staff "${TARGET_HOME}/.ssh"
install -m 600 -o "${TARGET_USER}" -g staff \
  /tmp/authorized_key.pub "${TARGET_HOME}/.ssh/authorized_keys"
rm -f /tmp/authorized_key.pub

# sshd drop-in disabling password auth. The 00- prefix wins over the shipped
# 100-macos.conf via "first occurrence wins" + OpenSSH's top-of-file Include
# directive, and /etc/ssh/sshd_config.d is Included by the stock sshd_config.
echo "==> Writing sshd drop-in to disable password auth..."
install -m 600 -o root -g wheel /dev/stdin "${TART_ROOT}/etc/ssh/sshd_config.d/00-vm-hardening.conf" <<'EOF'
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
# sshd -t LOADS the host keys to validate the config — measured on a real
# build: with them already gone it exits "no hostkeys available" and fails
# the build at this, the last, step. That is why host-key removal below is
# positioned AFTER this line, not simplified back above it alongside the
# other service teardown near the top of this script.
sshd -t
# `sshd -t` checks syntax and key sanity — it says nothing about which value
# WINS. The drop-in's whole premise is that `00-` outranks the base's shipped
# `100-macos.conf` under first-occurrence-wins, so read the EFFECTIVE config
# and assert the directives that matter actually took. This platform never
# locks the account password (see the manifest note above), which makes
# `passwordauthentication no` the only thing standing between a clone and the
# publicly-known admin password.
echo "==> Verifying sshd's effective config carries the hardening..."
sshd_effective="$(sshd -T)"
for want in \
  "passwordauthentication no" \
  "kbdinteractiveauthentication no" \
  "permitrootlogin no" \
  "pubkeyauthentication yes" \
  "streamlocalbindunlink yes"
do
  printf '%s\n' "$sshd_effective" | grep -qix "$want" || {
    echo "ERROR: sshd's effective configuration does not carry '${want}' — the drop-in was written but something outranks it. This image would ship with the posture it claims to close." >&2
    exit 1
  }
done

# macOS regenerates host keys itself: sshd runs via
# Program=/usr/libexec/sshd-keygen-wrapper under inetdCompatibility, which
# generates a missing set on the next connection and leaves it alone
# thereafter. So a clone mints its own keys with no unit, no marker file, and
# no ordering race against a socket-activated sshd — which could not express
# "before sshd" anyway, since launchd has no Before=.
#
# Positioned LAST, after sshd -t above (see the comment there): removing the
# keys any earlier makes that validation fail. Packer disconnects immediately
# after this script returns, so nothing downstream of this point depends on
# the keys being gone yet.
echo "==> Removing host keys so each clone generates its own on first connect..."
rm -f "${TART_ROOT}"/etc/ssh/ssh_host_*_key "${TART_ROOT}"/etc/ssh/ssh_host_*_key.pub

echo "==> 99-finalize.sh complete. Key authorized, remote-access services disabled, password auth disabled via sshd, host keys cleared, NOPASSWD sudo verified, listener surface verified."
