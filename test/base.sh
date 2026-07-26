#!/usr/bin/env bash
# Behavioral tests for 00-base.sh's guest-agent substrate gate — the check that
# turns an inherited, undeclared dependency into a declared one. The rest of
# 00-base.sh needs a booted guest (dnf/apt, systemd), so only this gate is
# driven here; the shipped block is READ OUT of the script rather than restated,
# so weakening it changes what these cases do. Plain bash, no framework.
set -uo pipefail

TEST_DIR=$(cd -P "$(dirname "$0")" >/dev/null 2>&1 && pwd)
REPO=$(cd -P "$TEST_DIR/.." >/dev/null 2>&1 && pwd)
BASE="$REPO/shared/scripts/00-base.sh"

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
# The stop anchor is the first real work in the script rather than a count of
# `fi` lines: counting would run past the end the moment a branch is added or
# removed, dragging in package installs and failing every case for the wrong
# reason instead of reporting the branch that went missing.
GATE="$WORK/gate.sh"
{
  printf 'set -euo pipefail\n'
  awk '
    /^agent_state=/  { emit=1 }
    /^echo "==> /    { if (emit) exit }
    emit             { print }
  ' "$BASE"
} > "$GATE"

# Only that a non-empty block about the right subject came across — enough to
# rule out every case below passing vacuously against an empty extraction. Which
# clauses the gate holds is what the cases measure.
if grep -q 'tart-guest-agent' "$GATE"; then
  ok "lifted the guest-agent gate out of 00-base.sh ($(grep -c . "$GATE") lines)"
else
  bad "lifted the guest-agent gate out of 00-base.sh" \
      "extraction produced $(grep -c . "$GATE") line(s) — the gate moved, or the awk anchor at test/base.sh:31 no longer matches it"
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
      enabled|enabled-runtime|static|indirect|generated|transient|alias) exit 0 ;;
      not-found)                                                        exit 4 ;;
      *)                                                                exit 1 ;;
    esac ;;
  is-active) exit "${MOCK_IS_ACTIVE_RC:-0}" ;;
  *) exit 4 ;;
esac
M
chmod +x "$MOCKBIN/systemctl"

# gate_verdict <is-enabled-state> <is-active-rc> — "pass" or "refuse"; stderr of
# the run is left in $GATE_ERR for the message assertions.
GATE_ERR=""
gate_verdict() {
  local rc=0
  GATE_ERR=$(PATH="$MOCKBIN:/usr/bin:/bin" MOCK_IS_ENABLED="$1" MOCK_IS_ACTIVE_RC="$2" \
    bash "$GATE" 2>&1) || rc=$?
  if [ "$rc" -eq 0 ]; then printf 'pass'; else printf 'refuse'; fi
}

# The healthy substrate — the only combination that may build.
assert_eq "enabled and running → build proceeds" "pass" "$(gate_verdict enabled 0)"

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
assert_contains "absent: gives a runnable next step"  "$GATE_ERR" "make bootstrap DISTRO="

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
