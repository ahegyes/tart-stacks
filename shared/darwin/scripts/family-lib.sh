#!/usr/bin/env bash
# family-lib.sh (darwin) — package-manager abstraction + integrity-posture
# primitive for the brew family, so shared/ and stacks/ provisioners never
# call brew directly. SOURCED, not run — uploaded to the SAME guest path
# (/tmp/family-lib.sh) as shared/linux/scripts/family-lib.sh, so every stack's
# 00-stack.sh sources one name regardless of platform. brew is this
# platform's only family; this file reaching a non-Darwin guest is a hard
# error, the same fail-closed rule the linux side applies to an unrecognized
# family.

# _detect_family — brew is the only family this platform has, so there is
# nothing to branch on; what this actually guards is the shared upload path:
# both platforms' libraries land at the same /tmp/family-lib.sh, so a build
# that uploaded the wrong one is the one way this ever fires.
_detect_family() {
  [ "$(uname -s)" = "Darwin" ] && printf 'brew'
}
_TART_FAMILY="$(_detect_family)" || {
  echo "family-lib.sh (darwin): sourced on a non-Darwin guest — the wrong platform's library reached this guest." >&2
  exit 1
}
export _TART_FAMILY

# MACOS_TARGET_RELEASE — the macOS release this platform ships as. A
# hand-maintained pin like FEDORA_TARGET_RELEASE on the linux side, and it
# rots the same way: nothing signals staleness on its own, so
# assert_release_supported compares the guest against it at build time.
MACOS_TARGET_RELEASE="${MACOS_TARGET_RELEASE:-26}"

# TART_BUILD_USER — Homebrew is owned by the unprivileged build user, and
# every system provisioner runs as root via sudo. Measured on a real macOS
# 26.5 VM: `brew install` as root exits 1 with "Running Homebrew as root is
# extremely dangerous and no longer supported", while `sudo -n -u <user> -i
# brew install` succeeds and the binary runs. `brew --version` does NOT
# reveal this — as root it still exits 0 with degraded output, so it can
# never stand in for a real install proof. Dropping privileges HERE, inside
# the abstraction, is what keeps 00-stack.sh one shared file across both
# platforms: it never has to know which platform needs the drop.
TART_BUILD_USER="${SUDO_USER:-admin}"

_brew() { sudo -n -u "$TART_BUILD_USER" -i brew "$@"; }

# pkg_refresh — refresh formula metadata, then apply pending upgrades. `brew
# update` alone only advances the tap (the metadata half); `brew upgrade` is
# the separate call that applies it, matching the linux contract's "refresh
# metadata + apply pending upgrades" in one call.
pkg_refresh() { _brew update && _brew upgrade; }

# pkg_install <pkg…> — install required formulae in ONE call; fail if any is
# missing. Guarded against an empty argv: `brew install` with no formulae is
# itself an error, and a caller with an empty package list means "nothing to
# do," not "fail."
pkg_install() {
  [ "$#" -gt 0 ] || return 0
  _brew install "$@"
}

pkg_installed() { _brew list --formula "$1" >/dev/null 2>&1; }

# pkg_install_optional <pkg…> — install what's available, skip the rest.
# Skips land in the same staging file 99-finalize.sh reads for the manifest,
# so a formula missing on darwin is as visible there as one missing on linux.
pkg_install_optional() {
  local skipfile="${TART_SKIPPED_FILE:-/tmp/tart-stacks-skipped}" p
  for p in "$@"; do
    _brew install "$p" >/dev/null 2>&1 || {
      echo "family-lib: optional package '$p' unavailable — skipped." >&2
      echo "$p" >> "$skipfile"
    }
  done
}

pkg_clean() { _brew cleanup --prune=all; }

# assert_integrity_enforced — the darwin half of the contract linux's peer
# implements with SELinux/AppArmor. Every Cirrus macOS base ships SIP AND
# Gatekeeper assessments disabled, and SIP cannot be re-enabled from inside a
# running system (only from recoveryOS), so asserting it would fail every
# build. The signed system volume (authenticated-root) is the integrity
# property that DOES hold on every such base, so that is what gates the
# build; SIP and Gatekeeper get recorded in the manifest instead of gated
# here.
assert_integrity_enforced() {
  local ssv
  ssv="$(csrutil authenticated-root status 2>/dev/null)"
  case "$ssv" in
    *enabled*) return 0 ;;
  esac
  echo "ERROR: the signed system volume is not sealed ('${ssv:-no answer}'). This base has had its system volume modified; refusing to ship an image whose system files carry no integrity guarantee." >&2
  return 1
}

# assert_release_supported — macOS publishes no SUPPORT_END equivalent, so
# unlike the linux branch this cannot read an end-of-life date out of the
# guest. It asserts the guest is not OLDER than the release this build
# claims to ship, which is the failure that actually occurs: a stale pulled
# base silently producing a mislabeled image.
assert_release_supported() {
  local major
  major="$(sw_vers -productVersion 2>/dev/null | cut -d. -f1)"
  case "$major" in
    ''|*[!0-9]*)
      echo "ERROR: could not read the guest's macOS version from sw_vers." >&2
      return 1 ;;
  esac
  [ "$major" -ge "$MACOS_TARGET_RELEASE" ] && return 0
  echo "ERROR: guest is macOS ${major}, older than MACOS_TARGET_RELEASE=${MACOS_TARGET_RELEASE}. The pulled base is stale — re-pull it, or lower the pin in this file deliberately." >&2
  return 1
}

# The launchd components Cirrus's own macos-image-templates installs:
# /Library/LaunchDaemons/org.cirruslabs.tart-guest-daemon.plist (root,
# --run-daemon: disk resize) and /Library/LaunchAgents/org.cirruslabs.tart-
# guest-agent.plist (per-user admin, --run-agent: clipboard + tart exec).
# Overridable so install_guest_agent is testable without writing under the
# real /Library.
TART_GUEST_DAEMON_PLIST="${TART_GUEST_DAEMON_PLIST:-/Library/LaunchDaemons/org.cirruslabs.tart-guest-daemon.plist}"
TART_GUEST_AGENT_PLIST="${TART_GUEST_AGENT_PLIST:-/Library/LaunchAgents/org.cirruslabs.tart-guest-agent.plist}"

# install_guest_agent — assert-only on darwin. Cirrus publishes the macOS
# base actively, so the version drift that made the linux build take
# ownership of a pinned agent doesn't occur here — there is nothing to
# install. Both components are asserted because tart exec is served by the
# per-user AGENT, not the root daemon: an image carrying only the daemon
# answers ssh cleanly and then fails every tart exec call, a fault far
# harder to place than a missing hostname.
install_guest_agent() {
  local p
  for p in "$TART_GUEST_DAEMON_PLIST" "$TART_GUEST_AGENT_PLIST"; do
    [ -f "$p" ] || {
      echo "ERROR: guest agent component '$p' is missing from this base. tart exec is a host->guest vsock call served by it, and nothing here installs it — a clone would answer ssh while tart-up could not set its hostname." >&2
      return 1
    }
  done
  return 0
}
