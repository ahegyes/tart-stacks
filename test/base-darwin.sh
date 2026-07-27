#!/usr/bin/env bash
# Behavioral tests for shared/darwin/scripts/00-base.sh's guest/release/agent
# asserts — the checks that must stop the build before any package work runs.
# The rest of 00-base.sh needs a booted macOS guest (brew, sudo), so only this
# region is driven here; the shipped block is READ OUT of the script rather
# than restated, so weakening it changes what these cases measure. Plain bash,
# no framework — same technique as test/base-linux.sh, its linux peer.
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
  ok "lifted the guest/release/agent asserts out of 00-base.sh ($(grep -c . "$GATE") lines)"
else
  bad "lifted the guest/release/agent asserts out of 00-base.sh" \
      "extraction produced $(grep -c . "$GATE") line(s) — the region moved, or the awk anchors at test/base-darwin.sh:38-40 no longer match it"
  printf '\n  %d passed, %d failed\n' "$pass" "$fail"
  exit 1
fi

# A `uname` that answers only `-s`, matching what the guard actually calls.
# Defaults to Darwin so a case that doesn't care about the guest kernel still
# runs against the ordinary substrate.
MOCKBIN="$WORK/bin"; mkdir -p "$MOCKBIN"
cat > "$MOCKBIN/uname" <<'M'
#!/usr/bin/env bash
[ "${1:-}" = "-s" ] && { printf '%s\n' "${MOCK_UNAME_S:-Darwin}"; exit 0; }
exit 1
M
chmod +x "$MOCKBIN/uname"

# gate_verdict <OS> <uname-s> [release-rc] [agent-rc] — "pass" or "refuse";
# stderr of the run is left in $GATE_ERR for the message assertion. The extra
# statuses are positional rather than environment prefixes on the call: bash
# leaves a `VAR=x func` assignment set after the function returns, which would
# silently arm it for every later case.
GATE_ERR=""
gate_verdict() {
  local rc=0
  GATE_ERR=$(PATH="$MOCKBIN:/usr/bin:/bin" OS="$1" MOCK_UNAME_S="$2" \
    MOCK_RELEASE_RC="${3:-0}" MOCK_AGENT_RC="${4:-0}" bash "$GATE" 2>&1) || rc=$?
  if [ "$rc" -eq 0 ]; then printf 'pass'; else printf 'refuse'; fi
}

# The healthy substrate — the only combination that may build. Without this
# case, a gate that refuses unconditionally would pass every case below for
# the wrong reason.
assert_eq "matching guest, supported release, whole agent → build proceeds" \
  "pass" "$(gate_verdict macos Darwin 0 0)"

# The os guard: the image name and provenance manifest are both written from
# OS, so a build whose declared OS doesn't match what it is running against
# must stop before any package work — not ship an image mislabeled as
# something it is not.
assert_eq "OS mismatch on a real Darwin guest → build refused" \
  "refuse" "$(gate_verdict fedora Darwin)"
gate_verdict fedora Darwin >/dev/null
assert_contains "OS mismatch: says WHY a wrong base is fatal" "$GATE_ERR" "mislabel"

# The release assert shares this region and must be able to stop the build on
# its own: a healthy agent is no reason to ship a guest older than the pin.
# Driving it through the stub's status proves 00-base.sh actually calls it,
# not merely that the text of the call is present.
assert_eq "unsupported release → build refused" \
  "refuse" "$(gate_verdict macos Darwin 1)"

# The agent assert shares this region and must be able to stop the build on
# its own. Driving it through the stub's status proves 00-base.sh actually
# calls it — a deleted call would otherwise leave this case green while images
# shipped whatever agent components their base happened to carry.
assert_eq "incomplete guest agent → build refused" \
  "refuse" "$(gate_verdict macos Darwin 0 1)"

printf '\n  %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
