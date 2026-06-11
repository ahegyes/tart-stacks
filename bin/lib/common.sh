# shellcheck shell=bash
# common.sh — leaf helpers shared by tart-up / tart-new / tart-ssh-sync /
# tart-supervise. Sourced, never on PATH / executable; bash-3.2-safe (macOS
# system bash). Pulls in the config-path resolver so a script sourcing this
# gets both. Helpers here take everything as arguments; the config-line
# parsers read script globals and stay in their owning scripts.

# shellcheck source=bin/lib/config.sh
. "${BASH_SOURCE[0]%/*}/config.sh"

# tart_need_cmd <tool> [install-hint] — preflight; exit 1 if the tool is missing.
tart_need_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "${prog:-${0##*/}}: '$1' not on PATH. ${2:-}" >&2; exit 1; }; }

# tart_vm_state <name> — print the VM's `tart list` State by exact name; empty
# output = no such VM. stderr stays attached so tart's (or jq's) real error
# reaches the terminal. A nonzero exit means the tool itself failed — callers
# must keep "broken tool" and "VM missing" distinct.
tart_vm_state() {
  tart list --format json | jq -r --arg name "$1" '.[] | select(.Name==$name) | .State'
}

# tart_supervise_label <vm> — the per-VM supervision LaunchAgent label.
# tart-supervise owns the agent lifecycle; tart-rm probes the same label to
# drop supervision before deleting a VM.
tart_supervise_label() { printf 'com.tart-stacks.supervise.%s' "$1"; }

# tart_valid_vm_name <name> — 0 iff the name is a token every consumer can
# carry: the ssh alias (tart-<name>), the guest hostname (`hostname -s` must
# equal the name, so no dots), and the vm-pattern grammar (commas are list
# separators, `*` is the wildcard). Letters/digits/_/-, alphanumeric head.
# Pure-bash glob classes: byte-exact in any locale, no subprocess per check.
tart_valid_vm_name() {
  case "$1" in
    ''|*[!A-Za-z0-9_-]*|[_-]*) return 1 ;;
  esac
  return 0
}

# tart_is_base_image <bare-name> <stacks-dir> <distros-file> — 0 if the name is a
# clone-source (the <distro>-base bootstrap intermediate, or a <distro>-<stack>
# built image), not a dev VM. Anchored on the supported distro set so hyphenated
# dev-VM names (e.g. web-php, app-base) are NOT misread as base images.
tart_is_base_image() {
  local bare="$1" stacks_dir="$2" distros_file="$3" d rest
  # The classification gates destructive paths (tart-rm's delete) — refusing
  # to answer beats silently failing open when the data is unreadable.
  [ -r "$distros_file" ] || { echo "${prog:-${0##*/}}: cannot read distros file '$distros_file' — cannot tell dev VMs from base images." >&2; exit 1; }
  [ -d "$stacks_dir" ]   || { echo "${prog:-${0##*/}}: stacks dir '$stacks_dir' not found — cannot tell dev VMs from base images." >&2; exit 1; }
  while IFS= read -r d; do
    case "$bare" in
      "$d"-base) return 0 ;;
      "$d"-*) rest="${bare#"$d"-}"; [ -d "$stacks_dir/$rest" ] && return 0 ;;
    esac
  done < <(grep -vE '^[[:space:]]*(#|$)' "$distros_file")
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
# (`tart run <vm> --no-graphics ...`). Anchoring to that position, rather than
# scanning every argument, is what stops a token inside a LATER argument (e.g.
# some other VM's `--dir=/path with <vm> in it`) from being mistaken for this VM
# running. The process — not `tart list` state — is the signal: a crash removes
# the process but can leave the listed state wedged at "running". (A manual
# option-first `tart run --opt <vm>` reads as down — the supervisor then
# restarts it into the canonical shape — fine, since tart-up is the only
# launcher in play.)
tart_vm_alive() {
  ps -axo args= 2>/dev/null | awk -v vm="$1" '
    {
      for (i = 1; i < NF; i++)
        if ($i ~ /(^|\/)tart$/ && $(i + 1) == "run" && $(i + 2) == vm) found = 1
    }
    END { exit(found ? 0 : 1) }
  '
}
