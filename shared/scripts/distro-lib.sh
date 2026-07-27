#!/usr/bin/env bash
# distro-lib.sh — package-manager + MAC-posture primitives so the shared/ and
# stacks/ provisioners never call dnf or apt directly. Families: dnf (Fedora),
# apt (Debian/Ubuntu). SOURCED, not run — uploaded to /tmp and sourced at the top of
# each system provisioner, like mise-lib.sh. An unrecognized distro is a hard error.

# _detect_family — print "dnf"|"apt" from os-release ID/ID_LIKE; rc 1 if neither.
# Reads $OS_RELEASE (default /etc/os-release) so it is unit-testable, and keeps the
# os-release vars local so they don't leak into the sourcing script.
_detect_family() {
  local ID="" ID_LIKE="" f="${OS_RELEASE:-/etc/os-release}"
  # shellcheck disable=SC1090
  [ -r "$f" ] && . "$f"
  # ID alone on the dnf side, ID_LIKE too on the apt side: the apt branch is
  # portable apt/dpkg, so a Debian derivative works, while the dnf branch needs
  # Fedora specifically (`rpm -E %fedora` for a COPR URL, `copr enable`, the
  # `development-tools` group). Every enterprise rebuild declares
  # ID_LIKE=fedora and would pass a laxer gate, then fail mid-build.
  case " ${ID} " in
    *" fedora "*) printf 'dnf'; return 0 ;;
  esac
  case " ${ID} ${ID_LIKE} " in
    *" debian "*|*" ubuntu "*) printf 'apt' ;;
    *) return 1 ;;
  esac
}

_DISTRO_FAMILY="$(_detect_family)" || {
  echo "distro-lib: unrecognized distro (os-release ID/ID_LIKE is neither dnf- nor apt-family)." >&2
  exit 1
}
export _DISTRO_FAMILY

# FEDORA_TARGET_RELEASE — the Fedora release dnf-family images are lifted to before
# anything is installed on them. The upstream base is published at a fixed release
# and its publisher bumps that by hand, so re-pulling the base never advances it;
# the release the image ships as is decided here instead.
#
# dnf upgrades at most TWO releases in one transaction, so this cannot simply track
# the newest Fedora — it is capped at the base's own release plus two.
# pkg_release_upgrade refuses a wider gap rather than attempting it.
FEDORA_TARGET_RELEASE="${FEDORA_TARGET_RELEASE:-44}"

# pkg_release_upgrade — lift a dnf-family guest to FEDORA_TARGET_RELEASE, then
# reboot. No-op on apt, whose bases are current and tracked by their publisher.
#
# On the dnf path this function DOES NOT RETURN: it blocks until the guest goes
# down. That is deliberate and load-bearing. `dnf offline reboot` only SCHEDULES
# the reboot and returns immediately, so a version of this that returned would let
# the next provisioner run inside the system-update boot — where the guest is still
# on the OLD release and dbus is refusing connections. That build succeeds and
# ships an image labelled as a release it is not running. The dying SSH session is
# the only signal the caller's expect_disconnect can act on, so the caller must set
# it, and nothing may follow this call in the same provisioner block.
pkg_release_upgrade() {
  local cur target hop
  case "$_DISTRO_FAMILY" in
    apt) return 0 ;;
    dnf) ;;
    # Fail closed rather than fall off the end of the case: a family added without
    # a branch here silently inherits whatever release its base was published at,
    # which is the exact problem this function exists to end.
    *)   echo "ERROR: no release-upgrade branch for package family '$_DISTRO_FAMILY' — add one before shipping images for it." >&2
         return 1 ;;
  esac

  cur="$(rpm -E %fedora)"
  target="$FEDORA_TARGET_RELEASE"

  # -ge, not -eq: once the upstream base is finally republished at or beyond the
  # target this becomes a no-op on its own, instead of attempting a downgrade or
  # needing to be removed by hand.
  if [ "$cur" -ge "$target" ]; then
    echo "==> Guest is already Fedora $cur (target $target) — no release upgrade needed."
    return 0
  fi

  hop=$((target - cur))
  if [ "$hop" -gt 2 ]; then
    echo "ERROR: dnf upgrades at most two releases at a time, but this guest is Fedora $cur" >&2
    echo "       and FEDORA_TARGET_RELEASE is $target — a $hop-release jump." >&2
    echo "       Crossing that needs one reboot per hop, and a reboot ends this provisioner," >&2
    echo "       so it cannot be looped here: reaching $target requires an additional" >&2
    echo "       release-upgrade provisioner block per hop in stack.pkr.hcl. Until those" >&2
    echo "       exist, lower FEDORA_TARGET_RELEASE to at most $((cur + 2))." >&2
    return 1
  fi

  echo "==> Upgrading Fedora $cur -> $target (the guest reboots; the build continues after it)..."
  dnf system-upgrade download --releasever="$target" -y
  dnf -y offline reboot
  # Reached only because `dnf offline reboot` returns as soon as the reboot is
  # queued. Block here so the session dies with the guest; see the header.
  sleep 300
  echo "ERROR: the guest did not go down within 300s of 'dnf offline reboot'." >&2
  return 1
}

# pkg_refresh — refresh metadata + apply pending upgrades.
pkg_refresh() {
  case "$_DISTRO_FAMILY" in
    dnf) dnf upgrade -y --refresh ;;
    apt) export DEBIAN_FRONTEND=noninteractive; apt-get update -y; apt-get upgrade -y ;;
  esac
}

# pkg_install <pkg…> — install required packages; fail if any is missing.
pkg_install() {
  case "$_DISTRO_FAMILY" in
    dnf) dnf install -y "$@" ;;
    apt) DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$@" ;;
  esac
}

# pkg_installed <pkg> — 0 iff the capability named by <pkg> is present. Consumers
# of the optional install path need this to tell "the family does not ship it"
# from "it is here under a name I did not expect", which look identical from a
# file probe. Resolved through Provides, the same way pkg_install_optional's
# post-check is: an exact-name query reads a compat rename as absent, and the one
# caller then silently drops a capability the image is carrying.
pkg_installed() {
  case "$_DISTRO_FAMILY" in
    dnf) rpm -q --whatprovides "$1" >/dev/null 2>&1 ;;
    apt) dpkg -s "$1" >/dev/null 2>&1 ;;
  esac
}

# pkg_install_optional <pkg…> — install what's available, warn on the rest
# (dnf has --skip-unavailable; apt has no equivalent, so loop per package).
# Skips are also appended to ${TART_SKIPPED_FILE:-/tmp/tart-stacks-skipped} so
# 99-finalize can record them in /etc/tart-stacks-release. dnf's flag is silent
# about WHICH packages it skipped, so that branch detects skips by post-checking
# the rpm database; apt's per-package loop knows directly.
pkg_install_optional() {
  local skipfile="${TART_SKIPPED_FILE:-/tmp/tart-stacks-skipped}" p policy showpkg
  case "$_DISTRO_FAMILY" in
    dnf) dnf install -y --skip-unavailable "$@"
         for p in "$@"; do
           # --whatprovides, not the bare name: dnf resolves a renamed package
           # through a compat `Provides`, which installs the capability under a
           # different rpm name. An exact-name post-check cannot see that and
           # would record a capability the image is carrying as skipped.
           rpm -q --whatprovides "$p" >/dev/null 2>&1 || {
             echo "distro-lib: optional package '$p' unavailable — skipped." >&2
             echo "$p" >> "$skipfile"
           }
         done ;;
    apt) export DEBIAN_FRONTEND=noninteractive
         for p in "$@"; do
           # Absence and failure are different outcomes, and only absence is a
           # droppable capability: a mirror outage, dependency conflict or full
           # disk recorded as "the archive does not carry this" is provenance
           # that lies precisely where it is most trusted. So the query's own
           # exit status is checked too — an apt-cache that FAILS says nothing
           # about availability, and treating its empty output as "no candidate"
           # would reintroduce the same lie one layer up.
           policy=$(apt-cache policy "$p") || return 1
           if [ -z "$(printf '%s\n' "$policy" | awk '/Candidate:/ && $2 != "(none)" { print $2 }')" ]; then
             # `Candidate: (none)` is also what a pure VIRTUAL package looks
             # like — no version of its own, but providers that apt-get install
             # resolves. So ask who provides it before believing the policy:
             # with providers, let the install decide (one resolves; several is
             # an ambiguous name in packages.apt, which must fail loudly rather
             # than drop a capability the archive carries).
             showpkg=$(apt-cache showpkg "$p") || return 1
             if [ -z "$(printf '%s\n' "$showpkg" | awk '/^Reverse Provides:/ { f = 1; next } f && NF { print $1 }')" ]; then
               echo "distro-lib: optional package '$p' unavailable — skipped." >&2
               echo "$p" >> "$skipfile"
               continue
             fi
           fi
           # Propagate explicitly rather than leaning on the caller's `set -e`:
           # reaching here means the archive has it, so a failure now is a
           # broken build, not a capability to drop.
           apt-get install -y --no-install-recommends "$p" || return 1
         done ;;
  esac
}

# pkg_group_devtools — the compiler + autotools build group.
pkg_group_devtools() {
  case "$_DISTRO_FAMILY" in
    dnf) dnf group install -y development-tools ;;
    apt) DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
           build-essential autoconf automake libtool pkg-config ;;
  esac
}

# pkg_clean — drop cached package data before the image is locked down.
pkg_clean() {
  case "$_DISTRO_FAMILY" in
    dnf) dnf clean all ;;
    apt) apt-get clean; rm -rf /var/lib/apt/lists/* ;;
  esac
}

# repo_add_mise — add the signed mise repo, then install mise. dnf: jdxcode/mise via
# a repofile (config-manager addrepo, not `copr enable` — that flaked writing the
# repofile mid-build; gpgcheck stays on). apt: the mise.jdx.dev signed apt repo.
repo_add_mise() {
  case "$_DISTRO_FAMILY" in
    dnf)
      local ver; ver="$(rpm -E %fedora)"
      dnf config-manager addrepo --from-repofile="https://copr.fedorainfracloud.org/coprs/jdxcode/mise/repo/fedora-${ver}/jdxcode-mise-fedora-${ver}.repo"
      dnf install -y mise ;;
    apt)
      export DEBIAN_FRONTEND=noninteractive
      apt-get install -y --no-install-recommends gpg ca-certificates curl
      install -dm 755 /etc/apt/keyrings
      curl -fsSL https://mise.jdx.dev/gpg-key.pub | gpg --dearmor -o /etc/apt/keyrings/mise-archive-keyring.gpg
      chmod 644 /etc/apt/keyrings/mise-archive-keyring.gpg
      echo "deb [signed-by=/etc/apt/keyrings/mise-archive-keyring.gpg arch=$(dpkg --print-architecture)] https://mise.jdx.dev/deb stable main" \
        > /etc/apt/sources.list.d/mise.list
      apt-get update -y; apt-get install -y --no-install-recommends mise ;;
  esac
}

# repo_add_github_cli — gh ships in dnf repos but not apt; add GitHub's signed apt
# repo there. No-op on dnf (gh comes from the base package set).
repo_add_github_cli() {
  case "$_DISTRO_FAMILY" in
    dnf) : ;;
    apt)
      export DEBIAN_FRONTEND=noninteractive
      apt-get install -y --no-install-recommends gpg ca-certificates curl
      install -dm 755 /etc/apt/keyrings
      curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
        -o /etc/apt/keyrings/githubcli-archive-keyring.gpg
      chmod 644 /etc/apt/keyrings/githubcli-archive-keyring.gpg
      echo "deb [signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg arch=$(dpkg --print-architecture)] https://cli.github.com/packages stable main" \
        > /etc/apt/sources.list.d/github-cli.list
      apt-get update -y ;;
  esac
}

# install_zellij — zellij isn't in the base repos. dnf: the varlad/zellij COPR
# (override via ZELLIJ_COPR). apt: the upstream static-musl release tarball; the
# published .sha256sum lists the *binary's* hash (not the tarball's), so verify the
# extracted binary against it, then install to /usr/local/bin (no apt package exists).
install_zellij() {
  case "$_DISTRO_FAMILY" in
    dnf) dnf copr enable -y "${ZELLIJ_COPR:-varlad/zellij}"; dnf install -y zellij ;;
    apt)
      local tmp asset sum base want bin
      asset="zellij-aarch64-unknown-linux-musl.tar.gz"
      sum="zellij-aarch64-unknown-linux-musl.sha256sum"
      base="https://github.com/zellij-org/zellij/releases/latest/download"
      tmp="$(mktemp -d)"
      curl -fsSL --retry 3 --retry-delay 2 "$base/$asset" -o "$tmp/$asset"
      curl -fsSL --retry 3 --retry-delay 2 "$base/$sum"   -o "$tmp/$sum"
      tar -xzf "$tmp/$asset" -C "$tmp"
      bin="$(find "$tmp" -type f -name zellij | head -n1)"
      want="$(awk '{print $1}' "$tmp/$sum")"
      if [ -z "$bin" ] || [ "$(sha256sum "$bin" | awk '{print $1}')" != "$want" ]; then
        echo "ERROR: zellij download missing or sha256 mismatch." >&2; rm -rf "$tmp"; return 1
      fi
      install -m 755 "$bin" /usr/local/bin/zellij
      rm -rf "$tmp" ;;
  esac
}

# TART_GUEST_AGENT_VERSION — the tart-guest-agent release every image installs.
#
# The agent answers the host's `tart exec` over vsock, and it arrives in the base
# image rather than from any distro repository — so its version is whatever the
# base happened to ship, and a base that stops being refreshed freezes it. That is
# not hypothetical: the frozen Fedora base carries 0.10.0 while the weekly-rebuilt
# Debian and Ubuntu bases carry 0.11.0, an invisible split across cells that are
# otherwise built identically. The release upgrade does not fix it either, since no
# repo provides the package for dnf to carry forward.
#
# Pinned rather than tracking the newest release: this binary executes what the
# host asks of it as a passwordless-sudo account, so the version installed is a
# thing to choose deliberately and verify, not to inherit from whatever shipped
# most recently. Bump here, then rebuild.
TART_GUEST_AGENT_VERSION="${TART_GUEST_AGENT_VERSION:-0.11.0}"

# install_guest_agent — install the pinned tart-guest-agent, verified against the
# release's published checksums, and make sure it is enabled and running.
#
# Upstream ships a native package per family, so this installs through the package
# manager rather than dropping a binary: dependencies resolve, and the systemd unit
# lands where the package intends it. The checksum step is not optional — see
# SECURITY.md for why this download in particular carries the weight it does.
install_guest_agent() {
  local ver="$TART_GUEST_AGENT_VERSION" arch ext pkg url tmp want got rc=0

  case "$(uname -m)" in
    aarch64|arm64) arch=arm64 ;;
    x86_64|amd64)  arch=amd64 ;;
    *) echo "ERROR: no tart-guest-agent build for machine type '$(uname -m)'." >&2; return 1 ;;
  esac
  case "$_DISTRO_FAMILY" in
    dnf) ext=rpm ;;
    apt) ext=deb ;;
    # Fail closed: a family without a branch would silently keep whatever agent its
    # base shipped, which is the split this function exists to close.
    *)   echo "ERROR: no tart-guest-agent package mapping for family '$_DISTRO_FAMILY' — add one before shipping images for it." >&2; return 1 ;;
  esac

  pkg="tart-guest-agent_${ver}_linux_${arch}.${ext}"
  url="https://github.com/openai/tart-guest-agent/releases/download/v${ver}"
  tmp="$(mktemp -d)"

  echo "==> Installing tart-guest-agent ${ver} (${arch}, ${ext})..."
  curl -fsSL --retry 3 --retry-delay 2 "$url/$pkg" -o "$tmp/$pkg" || rc=1
  curl -fsSL --retry 3 --retry-delay 2 "$url/tart-guest-agent_${ver}_checksums.txt" -o "$tmp/checksums" || rc=1
  if [ "$rc" -ne 0 ]; then
    echo "ERROR: could not download tart-guest-agent ${ver} from $url." >&2
    rm -rf "$tmp"; return 1
  fi

  # Match the whole filename, not a prefix: the checksums file lists .rpm, .deb,
  # .apk and the tarballs, and several names share a prefix with one another.
  want="$(awk -v p="$pkg" '$2 == p { print $1 }' "$tmp/checksums")"
  if [ -z "$want" ]; then
    echo "ERROR: '$pkg' has no entry in the ${ver} checksums file — refusing to install an unverifiable package." >&2
    rm -rf "$tmp"; return 1
  fi
  got="$(sha256sum "$tmp/$pkg" | awk '{print $1}')"
  if [ "$got" != "$want" ]; then
    echo "ERROR: sha256 mismatch for $pkg — expected $want, got $got." >&2
    rm -rf "$tmp"; return 1
  fi

  case "$_DISTRO_FAMILY" in
    dnf) dnf install -y "$tmp/$pkg" ;;
    apt) DEBIAN_FRONTEND=noninteractive apt-get install -y "$tmp/$pkg" ;;
  esac || { echo "ERROR: installing $pkg failed." >&2; rm -rf "$tmp"; return 1; }
  rm -rf "$tmp"

  # The package replaces a unit file the base image's older agent also owned, so
  # reload before enabling; `--now` because the assertions below read the running
  # state, and a clone's first boot needs it enabled regardless.
  systemctl daemon-reload
  systemctl enable --now tart-guest-agent.service
}

# assert_mac_enforcing — fail if the inherited mandatory-access-control layer isn't
# actively enforcing: SELinux in Enforcing mode on dnf; AppArmor with >0 profiles in
# enforce mode on apt (a loaded module alone wouldn't prove enforcement is happening).
# Every path here fails closed, including the two that mean "cannot tell": a query
# that errors, and a family with no branch. An assertion whose whole job is to fail
# a build must not pass by falling off the end of a case.
assert_mac_enforcing() {
  local m n
  case "$_DISTRO_FAMILY" in
    dnf) m="$(getenforce 2>/dev/null)" \
           || { echo "ERROR: getenforce failed or is unavailable — cannot confirm SELinux is enforcing." >&2; return 1; }
         [ "$m" = "Enforcing" ] || { echo "ERROR: SELinux is '${m:-unavailable}', expected 'Enforcing' — the base image's MAC posture regressed (inherited, not set by tart-stacks)." >&2; return 1; } ;;
    apt) n="$(aa-status --enforced 2>/dev/null)" \
           || { echo "ERROR: 'aa-status --enforced' failed or is unavailable — cannot confirm AppArmor is enforcing." >&2; return 1; }
         case "$n" in ''|*[!0-9]*) n=0 ;; esac
         [ "$n" -gt 0 ] || { echo "ERROR: AppArmor has no enforce-mode profiles — the base image's MAC posture regressed (inherited, not set by tart-stacks)." >&2; return 1; } ;;
    *)   echo "ERROR: no MAC assertion for package family '$_DISTRO_FAMILY' — add one before shipping images for it." >&2; return 1 ;;
  esac
}

# assert_release_supported — fail when the guest's own os-release declares a support
# window that has already closed. The release an image ships as is chosen by
# FEDORA_TARGET_RELEASE, a hand-maintained pin; this is what stops that pin going
# stale in silence, since an unpatched release otherwise looks exactly like a
# healthy one until a repository is purged mid-build months later.
#
# Fedora publishes SUPPORT_END. The apt family publishes no equivalent, so an
# absent field is a skip rather than a failure — its absence says nothing about
# support, and a gate that guessed would fail every Debian and Ubuntu build.
#
# Reads $OS_RELEASE (default /etc/os-release) and takes today from $TART_TODAY when
# set, so it is testable without a guest or a clock. Both dates are ISO-8601, which
# orders correctly as plain text. Local only: no network call, so this cannot become
# a new way for a build to flake.
assert_release_supported() {
  local f="${OS_RELEASE:-/etc/os-release}" today="${TART_TODAY:-}"
  local SUPPORT_END="" PRETTY_NAME=""
  # shellcheck disable=SC1090
  [ -r "$f" ] && . "$f"
  [ -n "$SUPPORT_END" ] || return 0
  [ -n "$today" ] || today="$(date -u +%Y-%m-%d)"
  [[ "$SUPPORT_END" < "$today" ]] || return 0
  echo "ERROR: ${PRETTY_NAME:-this guest} reached end of life on $SUPPORT_END (today is $today)." >&2
  echo "       Its repositories are no longer patched and are eventually purged, so this" >&2
  echo "       image would ship on a release nothing maintains — and the build that finally" >&2
  echo "       breaks would fail somewhere unrelated, long after the cause." >&2
  echo "       On the dnf family, raise FEDORA_TARGET_RELEASE in shared/scripts/distro-lib.sh" >&2
  echo "       (at most two releases above the base image's own) and rebuild." >&2
  return 1
}
