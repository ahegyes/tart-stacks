# shellcheck shell=bash
# common.sh — leaf helpers shared by the bin/ commands. Sourced, never on PATH
# / executable; bash-3.2-safe (macOS system bash). Pulls in the config-path resolver so a script sourcing this
# gets both. Helpers here take everything as arguments; the config-line
# parsers read script globals and stay in their owning scripts.

# shellcheck source=bin/lib/config.sh
. "${BASH_SOURCE[0]%/*}/config.sh"

# tart_need_cmd <tool> [install-hint] — preflight; exit 1 if the tool is missing.
tart_need_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "${prog:-${0##*/}}: '$1' not on PATH. ${2:-}" >&2; exit 1; }; }

# tart_vm_state <name> — print the local VM's `tart list` State by exact name;
# empty output = no such VM. Local only: `tart list` also shows the OCI images
# the build pulls, and running or deleting one of those would mutate the
# pristine cache copy rather than a dev VM (tart-new's image_built applies the
# same filter). stderr stays attached so tart's (or jq's) real error
# reaches the terminal. A nonzero exit means the tool itself failed — callers
# must keep "broken tool" and "VM missing" distinct.
tart_vm_state() {
  tart list --format json | jq -r --arg name "$1" '.[] | select(.Name==$name and .Source=="local") | .State'
}

# tart_vm_platform <name> — print the VM's platform as Tart itself reports it
# ("darwin" or "linux"), never the `<os>-<stack>` naming convention this
# repo's own images follow: that convention is a naming scheme this repo
# maintains, while `tart get`'s OS field is a property of the VM Tart
# actually built (confirmed empirically: `tart get macos-php --format json`
# answers `"OS":"darwin"`, `tart get fedora-php --format json` answers
# `"OS":"linux"`). Anything other than the literal "darwin" — a missing
# field, an unrecognized value, a failed `tart get` — falls safe onto linux,
# the platform every dev VM in this repo was until darwin existed.
tart_vm_platform() {
  case "$(tart get "$1" --format json 2>/dev/null | jq -r '.OS // empty' 2>/dev/null)" in
    darwin) printf 'darwin' ;;
    *)      printf 'linux'  ;;
  esac
}

# tart_resolve_vm <name> [not-found-hint] — print the stored VM name for a bare
# name or a `tart-<name>` SSH alias. The prefix is stripped unconditionally:
# tart_valid_vm_name refuses it at create time, so no tart-stacks VM can hold a
# `tart-*` name, and probing that form first would only ever match a VM made out
# of band with raw tart — never the one the caller meant. (The generated
# ProxyCommand strips it the same way, so honoring a literal match here would
# have ssh start one VM and connect to another.) Returns 1 on a miss or a broken
# `tart list`, having named which; callers exit on it rather than continuing with
# an empty name. Not usable as `local vm=$(...)` — `local` swallows the status.
tart_resolve_vm() {
  local vm="${1#tart-}" hint="${2:-}" state
  state=$(tart_vm_state "$vm") || {
    echo "${prog:-${0##*/}}: 'tart list' failed — cannot read VM states; see the error above." >&2
    return 1
  }
  [ -n "$state" ] || {
    echo "${prog:-${0##*/}}: VM '$vm' not found. Try 'tart list'.${hint}" >&2
    return 1
  }
  printf '%s' "$vm"
}

# tart_valid_vm_name <name> — 0 iff the name is a token every consumer can
# carry: the ssh alias (tart-<name>), the guest hostname (`hostname -s` must
# equal the name, so no dots), and the vm-pattern grammar (commas are list
# separators, `*` is the wildcard). Letters/digits/_/-, alphanumeric head.
# The `tart-` prefix itself is reserved for SSH aliases; alias-aware commands
# may strip it before resolving the bare stored VM name. Pure-bash glob
# classes: no subprocess per check. LC_ALL=C is what makes the ranges
# byte-exact — under a UTF-8 collation `[A-Za-z0-9_-]` also admits accented
# letters, so `café` would pass here and then fail as a hostname downstream.
tart_valid_vm_name() {
  local LC_ALL=C
  case "$1" in
    ''|*[!A-Za-z0-9_-]*|[_-]*|tart-*) return 1 ;;
  esac
  return 0
}

# tart_ssh_has_sessiontype — 0 iff the local ssh parses `Match sessiontype`
# (OpenSSH ≥ 10.0). The generated config gates its auto-start hook on that
# keyword, and older ssh treats it as a fatal Bad Match condition — activating
# the file on such a host would break every ssh invocation at once.
tart_ssh_has_sessiontype() {
  printf 'Match sessiontype shell\n' | ssh -G -F /dev/stdin __tart-probe >/dev/null 2>&1
}

# tart_is_base_image <bare-name> <stacks-dir> <os-glob> <desktops-file> —
# 0 if the name is a clone-source (the <os>-base bootstrap intermediate, a
# <os>-<stack> built image, or a <os>-<stack>-<de> GUI flavor), not a
# dev VM. Anchored on the supported OS set so hyphenated dev-VM names
# (e.g. web-php, app-base) are NOT misread as base images. <os-glob> scans
# every platform's os file (shared/*/os) rather than one hardcoded path: once
# `make bootstrap OS=macos` can clone a real macos-base (this repo now builds
# more than the linux platform), a caller that only knew shared/linux/os would
# wave a "macos-base" dev VM straight through. Desktops stay a single file —
# GUI flavors are a linux-only concept, so shared/linux/desktops is the only
# one that exists.
tart_is_base_image() {
  local bare="$1" stacks_dir="$2" os_glob="$3" desktops_file="$4" d de rest f
  # The classification gates destructive paths (tart-rm's delete) — refusing
  # to answer beats silently failing open when the data is unreadable.
  [ -d "$stacks_dir" ]    || { echo "${prog:-${0##*/}}: stacks dir '$stacks_dir' not found — cannot tell dev VMs from base images." >&2; exit 1; }
  [ -r "$desktops_file" ] || { echo "${prog:-${0##*/}}: cannot read desktops file '$desktops_file' — cannot tell dev VMs from base images." >&2; exit 1; }
  # shellcheck disable=SC2086  # deliberately unquoted: os_glob is a shell
  # glob (e.g. shared/*/os) expanding to one file per platform; a literal
  # path with no glob metacharacters expands to itself, unchanged.
  for f in $os_glob; do
    [ -r "$f" ] || { echo "${prog:-${0##*/}}: cannot read OS file '$f' — cannot tell dev VMs from base images." >&2; exit 1; }
    while IFS= read -r d; do
      case "$bare" in
        "$d"-base) return 0 ;;
        "$d"-*)
          rest="${bare#"$d"-}"
          [ -d "$stacks_dir/$rest" ] && return 0
          # GUI flavor: <stack>-<de>, de anchored on the supported desktop set
          # so a dev VM named e.g. fedora-php-2 stays a dev VM.
          while IFS= read -r de; do
            case "$rest" in
              *-"$de") [ -d "$stacks_dir/${rest%-"$de"}" ] && return 0 ;;
            esac
          done < <(grep -vE '^[[:space:]]*(#|$)' "$desktops_file")
          ;;
      esac
    done < <(grep -vE '^[[:space:]]*(#|$)' "$f")
  done
  return 1
}

# ---- vm-pattern helpers ----------------------------------------------------
# <vm-pattern> is `*` (any VM) | <name> | <a>,<b>,... (comma list, no spaces) —
# the selector grammar consumed by the mounts and forwards configs.

# tart_pattern_matches <pattern> <bare-vm> — 0 if the vm-pattern selects this VM.
tart_pattern_matches() {
  local pattern="$1" vm="$2"
  [ "$pattern" = "*" ] && return 0
  local -a names=()
  IFS=',' read -r -a names <<< "$pattern"
  local n
  for n in "${names[@]}"; do
    [ "$n" = "$vm" ] && return 0
  done
  return 1
}

# Resolve a vm-pattern to a space-joined list of host aliases for a `Host` line.
#   *            -> tart-*          (the wildcard; matches every dev VM)
#   <name>       -> tart-<name>
#   <a>,<b>,...  -> tart-<a> tart-<b> ...
# Names are emitted verbatim (no `tart list` check) — a forward for a VM that
# doesn't exist yet is inert until that VM is cloned.
tart_resolve_pattern() {
  local pattern=$1
  if [ "$pattern" = "*" ]; then
    printf 'tart-*'
    return 0
  fi
  local out=""
  local -a names=()
  IFS=',' read -r -a names <<< "$pattern"
  local n
  for n in "${names[@]}"; do
    out+="${out:+ }tart-$n"
  done
  printf '%s' "$out"
}

# ---- process liveness ------------------------------------------------------

# tart_vm_alive <vm> — 0 if a `tart run <vm>` process exists. Matches <vm> as the
# argument immediately after `tart run` — the shape tart-up always launches
# (`tart run <vm> …`). Anchoring to that position, rather than scanning every
# argument, is what stops a token inside a LATER argument (e.g. some other VM's
# `--dir=/path with <vm> in it`) from being mistaken for this VM running. The
# process — not `tart list` state — is the signal: a crash removes the process
# but can leave the listed state wedged at "running", which is what tart-up
# fail-fasts on. (A hand-run option-first `tart run --opt <vm>` reads as down;
# tart-up is the only launcher in play, so that shape does not occur here.)
tart_vm_alive() {
  ps -axo args= 2>/dev/null | awk -v vm="$1" '
    {
      for (i = 1; i < NF; i++)
        if ($i ~ /(^|\/)tart$/ && $(i + 1) == "run" && $(i + 2) == vm) found = 1
    }
    END { exit(found ? 0 : 1) }
  '
}
