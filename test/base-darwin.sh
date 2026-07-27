#!/usr/bin/env bash
# Behavioral tests for shared/darwin/scripts/00-base.sh: the os/release/agent
# asserts that must stop the build before any package work runs, plus (below)
# a static check that it pre-creates ~/.config/mise/ for the mise.toml upload
# later in the pipeline. That pre-creation exists because a real build once
# failed there: Packer's file provisioner does not create intermediate
# destination directories, and this script is darwin's only mise-owning
# script (mise ships in the Cirrus base, so there is no repo-add step the way
# linux's mise.sh has — see its comment below), so it is where the
# pre-creation has to live. Whether the guest itself is Darwin is
# family-lib.sh's assertion, not this script's, and
# lives in test/family-lib-darwin.sh; the window extracted below starts after
# that line for exactly this reason. The rest of 00-base.sh needs a booted
# macOS guest (brew, sudo, a real filesystem to chown), so only the assert
# region is driven by execution — the mise-dir case below is a static check
# against the shipped source instead, proven non-vacuous by mutation. The
# shipped block is READ OUT of the script rather than restated, so weakening
# it changes what these cases measure. Plain bash, no framework — same
# technique as test/base-linux.sh, its linux peer.
set -uo pipefail

TEST_DIR=$(cd -P "$(dirname "$0")" >/dev/null 2>&1 && pwd)
REPO=$(cd -P "$TEST_DIR/.." >/dev/null 2>&1 && pwd)
BASE="$REPO/shared/darwin/scripts/00-base.sh"

pass=0 fail=0
ok()  { pass=$((pass + 1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  FAIL %s\n         %s\n' "$1" "${2:-}"; }
assert_eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "want » $2 « got » $3 «"; fi; }
assert_contains() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "want » $3 « in: $2" ;; esac; }

WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT

# The os guard, plus the release and agent asserts, lifted out of the script
# and run for real — not reimplemented. A copy of the logic here would stay
# green while a shipped assert lost its `exit`. `set -euo pipefail` leads so
# the block runs under the same options 00-base.sh gives it.
#
# The window is bounded by landmarks, not by counting: it opens right after
# the `source /tmp/family-lib.sh` line and closes at the first real package
# work (`echo "==> Updating Homebrew`, immediately ahead of `pkg_refresh`).
# test/base-linux.sh's anchors (open after the os guard's `fi`, close at the
# next `echo "==> `) do NOT work here: on darwin the os guard is itself the
# FIRST thing in the assert region, and the line right after its `fi` is
# already an `echo "==> ` (the release-assert announcement) — that pair would
# open and close on the same boundary and capture nothing. Anchoring the open
# any later than the source line would leave the os guard itself outside the
# window; anchoring the close any earlier than the Homebrew line would leave
# the release or agent assert outside it.
GATE="$WORK/gate.sh"
{
  printf 'set -euo pipefail\n'
  # The region calls into family-lib.sh, which the real script sources above
  # the window and the fixture does not have. Supplied here alongside the
  # shell options for the same reason: to run the block under the shape
  # production gives it. Each stub's status is a knob rather than a fixed 0 so
  # the call itself stays measurable — stubbing it to always succeed would let
  # the call be deleted from 00-base.sh without a single case here noticing.
  # shellcheck disable=SC2016  # the expansions belong to the fixture, not to this shell
  printf 'assert_release_supported() { return "${MOCK_RELEASE_RC:-0}"; }\n'
  # shellcheck disable=SC2016
  printf 'install_guest_agent() { return "${MOCK_AGENT_RC:-0}"; }\n'
  awk '
    /^source \/tmp\/family-lib\.sh$/ { open = 1; next }
    /^echo "==> Updating Homebrew/   { if (open) exit }
    open { print }
  ' "$BASE"
} > "$GATE"

# Only that a non-empty block about the right subject came across — enough to
# rule out every case below passing vacuously against an empty extraction.
# Which clauses the gate holds is what the cases measure.
if grep -q 'mislabel' "$GATE"; then
  ok "lifted the os/release/agent asserts out of 00-base.sh ($(grep -c . "$GATE") lines)"
else
  bad "lifted the os/release/agent asserts out of 00-base.sh" \
      "extraction produced $(grep -c . "$GATE") line(s) — the region moved, or the awk anchors at test/base-darwin.sh:55-56 no longer match it"
  printf '\n  %d passed, %d failed\n' "$pass" "$fail"
  exit 1
fi

# gate_verdict <OS> [release-rc] [agent-rc] — "pass" or "refuse"; stderr of the
# run is left in $GATE_ERR for the message assertion. No uname mock: the
# window no longer calls uname (family-lib.sh owns that assertion, above the
# window — see the comment on the extraction above), so nothing here would
# exercise one. The extra statuses are positional rather than environment
# prefixes on the call: bash leaves a `VAR=x func` assignment set after the
# function returns, which would silently arm it for every later case.
GATE_ERR=""
gate_verdict() {
  local rc=0
  GATE_ERR=$(OS="$1" MOCK_RELEASE_RC="${2:-0}" MOCK_AGENT_RC="${3:-0}" \
    bash "$GATE" 2>&1) || rc=$?
  if [ "$rc" -eq 0 ]; then printf 'pass'; else printf 'refuse'; fi
}

# The healthy substrate — the only combination that may build. Without this
# case, a gate that refuses unconditionally would pass every case below for
# the wrong reason.
assert_eq "matching os token, supported release, whole agent → build proceeds" \
  "pass" "$(gate_verdict macos 0 0)"

# The os guard: the image name and provenance manifest are both written from
# OS, so a build whose declared OS doesn't match what it is running against
# must stop before any package work — not ship an image mislabeled as
# something it is not.
assert_eq "OS mismatch → build refused" \
  "refuse" "$(gate_verdict fedora)"
gate_verdict fedora >/dev/null
assert_contains "OS mismatch: says WHY a wrong base is fatal" "$GATE_ERR" "mislabel"

# The release assert shares this region and must be able to stop the build on
# its own: a healthy agent is no reason to ship a guest older than the pin.
# Driving it through the stub's status proves 00-base.sh actually calls it,
# not merely that the text of the call is present.
assert_eq "unsupported release → build refused" \
  "refuse" "$(gate_verdict macos 1)"

# The agent assert shares this region and must be able to stop the build on
# its own. Driving it through the stub's status proves 00-base.sh actually
# calls it — a deleted call would otherwise leave this case green while images
# shipped whatever agent components their base happened to carry.
assert_eq "incomplete guest agent → build refused" \
  "refuse" "$(gate_verdict macos 0 1)"

# mise_dir_check <file> — sets $MISE_DIR_LINE (whatever install -d
# .../.config/mise line, if any, <file> contains) and $MISE_DIR_VERDICT
# (pass/fail: owned by TART_BUILD_USER:staff). Static text match against the
# file's own line, not execution: doing this for real would need root and a
# writable /Users on the runner, neither of which CI has. Called directly,
# never through $(...) — a command substitution would run the call in a
# subshell and lose both globals, the same trap gate_verdict above avoids by
# leaving GATE_ERR to a direct call rather than a captured one.
MISE_DIR_LINE=""
MISE_DIR_VERDICT=""
mise_dir_check() {
  MISE_DIR_LINE=$(grep -E 'install -d .*\.config/mise"?$' "$1" || true)
  # shellcheck disable=SC2016  # matching 00-base.sh's own literal text, not expanding this shell's TART_BUILD_USER
  case "$MISE_DIR_LINE" in
    *'-o "$TART_BUILD_USER"'*'-g staff'*) MISE_DIR_VERDICT="pass" ;;
    *) MISE_DIR_VERDICT="fail" ;;
  esac
}

echo
echo "00-base.sh — pre-creates ~/.config/mise/ before the mise.toml upload:"

mise_dir_check "$BASE"
assert_eq "the shipped script creates it, owned by TART_BUILD_USER:staff" \
  "pass" "$MISE_DIR_VERDICT"
echo "         matched: ${MISE_DIR_LINE# }"

# Mutation 1: the group regresses to a linux-style guess (a user-private
# group, or root — what `install -d` defaults to with no -g at all). Printing
# the mutated line proves the sed pattern matched real content and actually
# changed it, rather than silently matching nothing and leaving the case
# trivially green.
sed 's/-g staff/-g admin/' "$BASE" > "$WORK/00-base-wrong-group.sh"
mise_dir_check "$WORK/00-base-wrong-group.sh"
assert_eq "a -g admin regression (wrong group) is caught" \
  "fail" "$MISE_DIR_VERDICT"
echo "         mutated line: ${MISE_DIR_LINE# }"

# Mutation 2: the line is gone entirely — the actual real-build failure this
# case exists to catch a repeat of (Packer's scp upload aborted with "No such
# file or directory" against a guest whose ~/.config/mise never got created).
grep -v 'install -d .*\.config/mise' "$BASE" > "$WORK/00-base-no-predir.sh"
mise_dir_check "$WORK/00-base-no-predir.sh"
assert_eq "no pre-creation at all is caught" \
  "fail" "$MISE_DIR_VERDICT"
echo "         mutated file: $(grep -c 'install -d' "$WORK/00-base-no-predir.sh" || true) 'install -d' line(s) left (want 0)"

printf '\n  %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
