#!/usr/bin/env bash
# mise-lib.sh — shared helpers for the per-stack mise-install.sh scripts.
#
# SOURCED, not run: the Packer template uploads this to /tmp/mise-lib.sh (a `file`
# provisioner) and each stack's mise-install.sh sources it. It can't live in a
# `scripts=[]` provisioner — those run each script in its own shell, so the
# functions wouldn't survive to the stack script. Stack-specific tool payloads and
# smoke checks stay in the stack's own mise-install.sh; this is only the invariant
# mechanism every mise-based stack repeats.

# mise_runtime_setup — install everything declared in the uploaded mise.toml,
# activate mise for the rest of the calling script, and enable Corepack. Runs as
# the unprivileged build user (mise installs under ~/.local/share/mise/). Activation
# persists because callers invoke this in the script's own shell, not a subshell.
mise_runtime_setup() {
  export PATH="$HOME/.local/bin:$PATH"
  echo "==> Installing language runtimes per global mise.toml..."
  # -y auto-accepts plugin trust prompts; --verbose surfaces real build/compile
  # errors (otherwise mise summarizes them out of the build log).
  mise install -y --verbose
  echo ""
  echo "==> Installed tools:"
  mise list
  # Activate so mise-managed binaries are on PATH for the rest of the script.
  eval "$(mise activate bash)"
  # Staged for /etc/tart-stacks-release — 99-finalize composes the manifest.
  mise list > /tmp/tart-stacks-tools 2>/dev/null || true
  # Corepack: flip pnpm/yarn shims to each project's package.json "packageManager".
  # Gated: corepack ships with Node, and a stack whose mise.toml omits Node must
  # not fail in a shared-lib line its author never wrote.
  echo ""
  if command -v corepack >/dev/null 2>&1; then
    echo "==> Enabling Corepack for per-project pnpm/yarn shimming..."
    corepack enable
    # corepack writes pnpm/yarn into the node install's bin dir AFTER mise's last
    # reshim, so they ship with no shim of their own — invisible to any PATH that
    # carries only the shims dir, which is every non-interactive `ssh <vm> <cmd>`.
    mise reshim
  else
    echo "==> corepack not present (no Node in this stack) — skipping Corepack."
  fi
}

# membership_gate <label> <listing> <name…> — HARD GATE for a stack whose smoke
# is membership-based rather than command-based: check each <name> against a
# listing the caller already captured, print one line per name, and exit 1 if any
# is absent so the Packer build fails rather than shipping a broken toolchain.
#
# The match is line-anchored and case-insensitive, and both halves are
# load-bearing. `php -m` spells opcache "Zend OPcache", hence -i. And PHP CLI's
# display_errors writes "Warning: PHP Startup: Unable to load dynamic library
# 'imagick.so'" to the SAME stdout the listing comes from — so an unanchored
# match reads that warning as proof the extension loaded, passing the gate in
# exactly the case it exists to catch (measured on a live clone: `grep -qiF`
# matches an extension absent from [PHP Modules], `grep -qixF` does not).
#
# A herestring, not `printf | grep`: `grep -q` exits at the first match, and on a
# listing past the pipe buffer printf then takes SIGPIPE, which pipefail reports
# as 141 — a found name would read as missing.
membership_gate() {
  local label="$1" listing="$2"
  shift 2
  echo ""
  echo "==> Smoke test (hard gate): $label"
  local missing=0 name
  for name in "$@"; do
    printf "  %-12s " "$name"
    if grep -qixF "$name" <<<"$listing"; then
      echo "loaded"
    else
      echo "(missing)"
      missing=$((missing + 1))
    fi
  done
  if [ "$missing" -gt 0 ]; then
    echo "" >&2
    echo "ERROR: $missing of the expected $label did not load. Fix the build environment and re-run." >&2
    exit 1
  fi
}

# smoke_gate <label> -- <cmd> [args…] [-- <cmd> [args…]]… — HARD GATE: run each
# `--`-delimited argv group, print its first meaningful output line, and exit 1
# if any fails, so the Packer build fails rather than shipping a broken
# toolchain. Argv groups (never strings, never eval) keep arguments word-split-
# safe for every future stack author. Empty groups (doubled or trailing `--`)
# are ignored. For command-based stacks (jvm, python); membership_gate above is
# the counterpart for a listing (php's `php -m`).
smoke_gate() {
  local label="$1"; shift
  echo ""
  echo "==> Smoke test (hard gate): $label"
  local output failed=0 tok
  local -a cmd=()
  # A trailing sentinel so the loop flushes the final group uniformly.
  set -- "$@" --
  for tok in "$@"; do
    if [ "$tok" != "--" ]; then cmd+=("$tok"); continue; fi
    [ "${#cmd[@]}" -gt 0 ] || continue
    printf "  %-26s " "${cmd[*]}"
    # First non-empty, non-separator line (e.g. `gradle --version` leads with a box border).
    if output=$("${cmd[@]}" 2>&1); then
      echo "$output" | awk '/^[^-]/ && NF { print; exit }'
    else
      echo "FAILED"
      echo "$output" >&2
      failed=$((failed + 1))
    fi
    cmd=()
  done
  if [ "$failed" -gt 0 ]; then
    echo "" >&2
    echo "ERROR: $failed check(s) failed in '$label'. Fix the build environment and re-run." >&2
    exit 1
  fi
}
