#!/usr/bin/env bash
# distro-lib.sh — package-manager + MAC-posture primitives so the shared/ and
# stacks/ provisioners never call dnf or apt directly. Families: dnf (Fedora/RHEL),
# apt (Debian/Ubuntu). SOURCED, not run — uploaded to /tmp and sourced at the top of
# each system provisioner, like mise-lib.sh. An unrecognized distro is a hard error.

# _detect_family — print "dnf"|"apt" from os-release ID/ID_LIKE; rc 1 if neither.
# Reads $OS_RELEASE (default /etc/os-release) so it is unit-testable, and keeps the
# os-release vars local so they don't leak into the sourcing script.
_detect_family() {
  local ID="" ID_LIKE="" f="${OS_RELEASE:-/etc/os-release}"
  # shellcheck disable=SC1090
  [ -r "$f" ] && . "$f"
  case " ${ID} ${ID_LIKE} " in
    *" fedora "*|*" rhel "*)   printf 'dnf' ;;
    *" debian "*|*" ubuntu "*) printf 'apt' ;;
    *) return 1 ;;
  esac
}

_DISTRO_FAMILY="$(_detect_family)" || {
  echo "distro-lib: unrecognized distro (os-release ID/ID_LIKE is neither dnf- nor apt-family)." >&2
  exit 1
}
export _DISTRO_FAMILY

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

# pkg_install_optional <pkg…> — install what's available, warn on the rest
# (dnf has --skip-unavailable; apt has no equivalent, so loop per package).
pkg_install_optional() {
  case "$_DISTRO_FAMILY" in
    dnf) dnf install -y --skip-unavailable "$@" ;;
    apt) export DEBIAN_FRONTEND=noninteractive; local p
         for p in "$@"; do
           apt-get install -y --no-install-recommends "$p" \
             || echo "distro-lib: optional package '$p' unavailable — skipped." >&2
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
      dnf install -y dnf-plugins-core
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

# assert_mac_enforcing — fail if the inherited mandatory-access-control layer isn't
# actively enforcing: SELinux in Enforcing mode on dnf; AppArmor with >0 profiles in
# enforce mode on apt (a loaded module alone wouldn't prove enforcement is happening).
assert_mac_enforcing() {
  case "$_DISTRO_FAMILY" in
    dnf) local m; m="$(getenforce 2>/dev/null || true)"
         [ "$m" = "Enforcing" ] || { echo "ERROR: SELinux is '${m:-unavailable}', expected 'Enforcing'." >&2; return 1; } ;;
    apt) local n; n="$(aa-status --enforced 2>/dev/null || true)"
         case "$n" in ''|*[!0-9]*) n=0 ;; esac
         [ "$n" -gt 0 ] || { echo "ERROR: AppArmor has no profiles in enforce mode." >&2; return 1; } ;;
  esac
}
