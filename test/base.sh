#!/usr/bin/env bash
# Behavioral tests for 00-base.sh's guest-agent substrate gate — the check that
# turns an inherited, undeclared dependency into a declared one. `tart exec` is
# a host->guest vsock call served by tart-guest-agent INSIDE the guest; Packer
# and every toolchain probe use ssh, so without this gate a base missing the
# agent builds clean and only fails once a consumer asks tart-up for a hostname
# or a desktop. The rest of 00-base.sh needs a booted guest (dnf/apt, systemd),
# so only this gate is driven here; the shipped block is READ OUT of the script
# rather than restated, so weakening it changes what these cases do. Plain bash,
# no framework.
set -uo pipefail

TEST_DIR=$(cd -P "$(dirname "$0")" >/dev/null 2>&1 && pwd)
REPO=$(cd -P "$TEST_DIR/.." >/dev/null 2>&1 && pwd)
BASE="$REPO/shared/scripts/00-base.sh"

pass=0 fail=0
ok()  { pass=$((pass + 1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  FAIL %s\n         %s\n' "$1" "${2:-}"; }
assert_eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "want » $2 « got » $3 «"; fi; }
assert_contains() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "want » $3 « in: $2" ;; esac; }

WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT

# The gate itself, lifted out of the script and run for real — not
# reimplemented. A copy of the logic here would stay green while the shipped
# branch lost its `exit 1`, or its `is-enabled` clause. `set -euo pipefail`
# leads so the block runs under the same options 00-base.sh gives it.
GATE="$WORK/gate.sh"
{
  printf 'set -euo pipefail\n'
  awk '
    /^if ! command -v tart-guest-agent /  { emit=1 }
    emit                                  { print }
    emit && /^fi$/                        { exit }
  ' "$BASE"
} > "$GATE"

# Only that a non-empty block about the right subject came across — enough to
# rule out every case below passing vacuously against an empty file, and no
# more. Which clauses it contains and whether it refuses are what the behavioral
# cases measure; asserting them here too would turn a legitimate refactor of the
# gate into a failure while proving nothing the cases do not.
if grep -q 'tart-guest-agent' "$GATE"; then
  ok "lifted the guest-agent gate out of 00-base.sh ($(grep -c . "$GATE") lines)"
else
  bad "lifted the guest-agent gate out of 00-base.sh" \
      "extraction produced $(grep -c . "$GATE") line(s) — the gate moved or changed shape"
  printf '\n  %d passed, %d failed\n' "$pass" "$fail"
  exit 1
fi

# The guest side, faked: a `tart-guest-agent` on PATH and a `systemctl` whose
# is-enabled status is a knob. Both states are real ones — rc=1 is a unit that
# exists but is disabled (it would never start on a clone's first boot), rc=4 is
# no such unit at all. Measured on a live guest, where the healthy answer is 0.
MOCKBIN="$WORK/bin"; mkdir -p "$MOCKBIN"
# shellcheck disable=SC2016  # the knob is written INTO the mock, for the mock to
# expand when the gate runs it — not for this shell
printf '#!/usr/bin/env bash\nexit "${MOCK_IS_ENABLED_RC:-0}"\n' > "$MOCKBIN/systemctl"
printf '#!/usr/bin/env bash\nexit 0\n' > "$MOCKBIN/tart-guest-agent"
chmod +x "$MOCKBIN/systemctl" "$MOCKBIN/tart-guest-agent"

# gate_verdict <agent-present:yes|no> <is-enabled-rc> — "pass", or "refuse".
# Stderr of the last run is left in $GATE_ERR for the message assertions.
GATE_ERR=""
gate_verdict() {
  local rc=0
  if [ "$1" = yes ]; then chmod +x "$MOCKBIN/tart-guest-agent"
  else rm -f "$MOCKBIN/tart-guest-agent"; fi
  # A PATH of exactly the mocks plus the system dirs: `tart-guest-agent` must be
  # absent for real in the "no" case, and nothing on this host provides it.
  GATE_ERR=$(PATH="$MOCKBIN:/usr/bin:/bin" MOCK_IS_ENABLED_RC="$2" bash "$GATE" 2>&1) || rc=$?
  # Restore for the next case regardless of which branch ran.
  printf '#!/usr/bin/env bash\nexit 0\n' > "$MOCKBIN/tart-guest-agent"
  chmod +x "$MOCKBIN/tart-guest-agent"
  if [ "$rc" -eq 0 ]; then printf 'pass'; else printf 'refuse'; fi
}

# The healthy substrate — the only combination that may build.
assert_eq "agent installed and enabled → build proceeds" "pass" "$(gate_verdict yes 0)"

# Each half alone is insufficient, and for different reasons: an absent binary
# means the unit cannot run, an unenabled unit means it never starts on the
# clone. Either way `tart exec` is dead for every VM made from this image.
assert_eq "agent binary absent → build refused"        "refuse" "$(gate_verdict no 0)"
assert_eq "unit present but disabled → build refused"  "refuse" "$(gate_verdict yes 1)"
assert_eq "no such unit (rc 4) → build refused"        "refuse" "$(gate_verdict yes 4)"
assert_eq "neither present → build refused"            "refuse" "$(gate_verdict no 4)"

# The refusal has to send the reader to the base image, not to this build: the
# fix is never in tart-stacks' provisioners, and "the host has tart installed"
# is the wrong intuition to leave intact.
gate_verdict no 4 >/dev/null
assert_contains "refusal names the missing unit"      "$GATE_ERR" "tart-guest-agent.service"
assert_contains "refusal says the channel is not ssh" "$GATE_ERR" "vsock"
assert_contains "refusal rules out a host-side fix"   "$GATE_ERR" "host's own tart install cannot supply it"
assert_contains "refusal names the consequence"       "$GATE_ERR" "GUI activation fails"
assert_contains "refusal says where to fix it"        "$GATE_ERR" "base image"

printf '\n  %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
