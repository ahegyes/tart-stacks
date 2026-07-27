#!/usr/bin/env bash
# Behavioral tests for shared/linux/scripts/00-base.sh's guest-agent substrate
# gate — the check that turns an inherited, undeclared dependency into a
# declared one. The rest of 00-base.sh needs a booted guest (dnf/apt, systemd),
# so only this gate is driven here; the shipped block is READ OUT of the script
# rather than restated, so weakening it changes what these cases do. Plain
# bash, no framework. test/base-darwin.sh is the darwin peer.
set -uo pipefail

TEST_DIR=$(cd -P "$(dirname "$0")" >/dev/null 2>&1 && pwd)
REPO=$(cd -P "$TEST_DIR/.." >/dev/null 2>&1 && pwd)
BASE="$REPO/shared/linux/scripts/00-base.sh"

pass=0 fail=0
ok()  { pass=$((pass + 1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  FAIL %s\n         %s\n' "$1" "${2:-}"; }
assert_eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "want » $2 « got » $3 «"; fi; }
assert_contains() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "want » $3 « in: $2" ;; esac; }
assert_absent()   { case "$2" in *"$3"*) bad "$1" "should NOT contain » $3 «" ;; *) ok "$1" ;; esac; }

WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT

# Both gate branches, lifted out of the script and run for real — not
# reimplemented. A copy of the logic here would stay green while a shipped
# branch lost its `exit 1`. `set -euo pipefail` leads so the block runs under
# the same options 00-base.sh gives it.
# The window is bounded by landmarks, not by counting: it opens after the
# os-release gate's `fi` and closes at the first real work in the script. Both
# ends matter. Counting `fi` lines would run past the end the moment a branch is
# added or removed, dragging package installs into the fixture and failing every
# case for the wrong reason. Anchoring the start on `agent_state=` instead would
# make any refusal added ABOVE that line invisible here — the whole
# substrate-assertion region belongs in the window, not just today's first line
# of it.
GATE="$WORK/gate.sh"
{
  printf 'set -euo pipefail\n'
  # The region calls into family-lib.sh, which the real script sources above the
  # window and the fixture does not have. Supplied here alongside the shell options
  # for the same reason: to run the block under the shape production gives it.
  # Its status is a knob rather than a fixed 0 so the call itself stays measurable —
  # stubbing it to always succeed would let the call be deleted from 00-base.sh
  # without a single case here noticing.
  # shellcheck disable=SC2016  # the expansions belong to the fixture, not to this shell
  printf 'assert_release_supported() { return "${MOCK_RELEASE_RC:-0}"; }\n'
  # shellcheck disable=SC2016
  printf 'install_guest_agent() { return "${MOCK_AGENT_INSTALL_RC:-0}"; }\n'
  awk '
    /^fi$/        { if (!open) { open = 1; next } }
    /^echo "==> / { if (open) exit }
    open          { print }
  ' "$BASE"
} > "$GATE"

# Only that a non-empty block about the right subject came across — enough to
# rule out every case below passing vacuously against an empty extraction. Which
# clauses the gate holds is what the cases measure.
if grep -q 'tart-guest-agent' "$GATE"; then
  ok "lifted the guest-agent gate out of 00-base.sh ($(grep -c . "$GATE") lines)"
else
  bad "lifted the guest-agent gate out of 00-base.sh" \
      "extraction produced $(grep -c . "$GATE") line(s) — the gate moved, or the awk anchor at test/base-linux.sh:32 no longer matches it"
  printf '\n  %d passed, %d failed\n' "$pass" "$fail"
  exit 1
fi

# A `systemctl` that answers per subcommand. Without the case, every subcommand
# would share one knob and swapping is-enabled for is-active in production would
# leave all these cases green.
#
# is-enabled's exit status is derived from the state it reports, per systemctl(1)
# — and the derivation is the whole point: the manual returns 0 for `static`,
# `enabled-runtime`, `indirect`, `generated` and `transient` as well as
# `enabled`. A mock that failed those would hide the difference between keying
# the gate on the exit status and keying it on the literal string, which is
# exactly the distinction the cases below exist to measure.
MOCKBIN="$WORK/bin"; mkdir -p "$MOCKBIN"
cat > "$MOCKBIN/systemctl" <<'M'
#!/usr/bin/env bash
case "$1" in
  is-enabled)
    printf '%s\n' "${MOCK_IS_ENABLED-enabled}"
    case "${MOCK_IS_ENABLED-enabled}" in
      enabled|enabled-runtime|static|indirect|generated|alias) exit 0 ;;
      not-found)                                               exit 4 ;;
      *)                                                       exit 1 ;;
    esac ;;
  is-active) exit "${MOCK_IS_ACTIVE_RC:-0}" ;;
  *) exit 4 ;;
esac
M
chmod +x "$MOCKBIN/systemctl"

# gate_verdict <is-enabled-state> <is-active-rc> [release-gate-rc] [agent-install-rc]
# — "pass" or "refuse"; stderr of the run is left in $GATE_ERR for the message
# assertions. The extra statuses are positional rather than environment prefixes on
# the call: bash leaves a `VAR=x func` assignment set after the function returns,
# which would silently arm it for every later case.
GATE_ERR=""
gate_verdict() {
  local rc=0
  GATE_ERR=$(PATH="$MOCKBIN:/usr/bin:/bin" MOCK_IS_ENABLED="$1" MOCK_IS_ACTIVE_RC="$2" \
    MOCK_RELEASE_RC="${3:-0}" MOCK_AGENT_INSTALL_RC="${4:-0}" bash "$GATE" 2>&1) || rc=$?
  if [ "$rc" -eq 0 ]; then printf 'pass'; else printf 'refuse'; fi
}

# The healthy substrate — the only combination that may build.
assert_eq "enabled and running → build proceeds" "pass" "$(gate_verdict enabled 0)"

# The release gate shares this region and must be able to stop the build on its
# own: a healthy agent is no reason to ship an end-of-life release. Driving it
# through the stub's status proves 00-base.sh actually calls it and that a refusal
# propagates, rather than proving the text of the call is present.
assert_eq "end-of-life release → build refused"  "refuse" "$(gate_verdict enabled 0 1)"

# The agent install shares this region and must be able to stop the build on its
# own. Driving it through the stub's status proves 00-base.sh actually calls it —
# a deleted call would otherwise leave every case here green while images shipped
# whatever agent their base happened to carry, which is the drift being closed.
assert_eq "agent install fails → build refused"  "refuse" "$(gate_verdict enabled 0 0 1)"

# Anything other than the literal `enabled` fails the first branch. `static` and
# `enabled-runtime` are the two that matter: real systemctl exits 0 for both, so
# a gate keyed on exit status would accept them silently. Whether either actually
# starts on a clone depends on what else pulls the unit in, which the gate cannot
# see — so refusing and naming the state is the deliberate choice.
assert_eq "unit disabled → build refused"        "refuse" "$(gate_verdict disabled 0)"
assert_eq "no such unit → build refused"         "refuse" "$(gate_verdict not-found 0)"
assert_eq "static unit → build refused"          "refuse" "$(gate_verdict static 0)"
assert_eq "enabled-runtime → build refused"      "refuse" "$(gate_verdict enabled-runtime 0)"

# The second branch: enabled only promises systemd will try. An agent that dies
# at startup here dies the same way on every clone, and `tart exec` is dead
# either way — measured on a live guest, where a stopped-but-enabled unit still
# reports is-enabled=enabled with exit 0.
assert_eq "enabled but not running → build refused" "refuse" "$(gate_verdict enabled 3)"

# Each branch has to send the reader somewhere different, because the fixes are
# different: install-and-enable it versus find out why it dies.
gate_verdict not-found 0 >/dev/null
assert_contains "absent: names the missing unit"      "$GATE_ERR" "tart-guest-agent.service"
assert_contains "absent: reports the state it saw"    "$GATE_ERR" "not-found"
assert_contains "absent: says the channel is vsock"   "$GATE_ERR" "vsock"
assert_contains "absent: rules out a host-side fix"   "$GATE_ERR" "host's own tart install cannot supply it"
# The build installs this package itself, so the fix is the pin and the install
# output — not the base image. Naming the knob is the runnable next step.
assert_contains "absent: points at the version pin"   "$GATE_ERR" "TART_GUEST_AGENT_VERSION"
# Re-pulling the base was the right advice while the base owned the agent. Now it
# is a loop that changes nothing, so the message has to say so rather than stay
# silent and let a reader reach for the habit.
assert_contains "absent: rules out re-pulling a base" "$GATE_ERR" "Re-pulling a base cannot fix"
assert_absent   "absent: no longer advises bootstrap" "$GATE_ERR" "make bootstrap"

gate_verdict disabled 0 >/dev/null
assert_contains "disabled: reports the state it saw"  "$GATE_ERR" "disabled"

gate_verdict enabled 3 >/dev/null
assert_contains "dead agent: distinguishes itself"    "$GATE_ERR" "enabled but not running"
assert_contains "dead agent: names the consequence"   "$GATE_ERR" "no GUI mode can start"
assert_contains "dead agent: points at the journal"   "$GATE_ERR" "systemctl status"
# Re-bootstrapping replaces the base image, which is the wrong move for an agent
# that IS installed and enabled — so that advice must not leak into this branch.
assert_absent   "dead agent: does not say re-bootstrap" "$GATE_ERR" "make bootstrap"

printf '\n  %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
