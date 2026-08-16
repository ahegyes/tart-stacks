#!/usr/bin/env bash
# Contract tests for the darwin display-mode applier that tart-up delivers into
# a macOS guest on a window boot.
#
# The applier is Swift, not shell, so its regressions are compile errors that
# surface only on a real macOS guest's first boot — long after the change that
# caused them. A host typecheck is what catches them here instead.
#
# ONLY the argument-validation paths are executed. They return before the first
# CoreGraphics call, so nothing here can read — let alone reconfigure — the
# HOST's own display; a run with a valid geometry deliberately is not made.
# Plain bash, no framework. Run via script/test or directly.
set -uo pipefail

TEST_DIR=$(cd -P "$(dirname "$0")" >/dev/null 2>&1 && pwd)
REPO=$(cd -P "$TEST_DIR/.." >/dev/null 2>&1 && pwd)
APPLIER="$REPO/shared/darwin/runtime/display-mode.swift"

pass=0 fail=0
ok()  { pass=$((pass + 1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  FAIL %s\n         %s\n' "$1" "${2:-}"; }
assert_contains() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "want » $3 « in: $2" ;; esac; }
assert_rc() { # label want cmd...
  local l="$1" want="$2"; shift 2; local got=0
  "$@" >/dev/null 2>&1 || got=$?
  if [ "$got" -eq "$want" ]; then ok "$l"; else bad "$l" "want rc=$want got rc=$got"; fi
}

echo "display-mode — the applier exists and tart-up points at it:"
if [ -r "$APPLIER" ]; then ok "applier is readable"; else bad "applier is readable" "missing: $APPLIER"; fi
assert_contains "tart-up resolves the applier from the repo" \
  "$(cat "$REPO/bin/tart-up")" 'shared/darwin/runtime/display-mode.swift'
assert_contains "tart-up delivers it to a stable guest path" \
  "$(cat "$REPO/bin/tart-up")" '/tmp/tart-stacks-display-mode.swift'

# Asserted against the CODE with comments stripped: the header prose mentions
# `.permanently` too, so a whole-file match passes even when the call that
# writes the preference has been changed to a for-this-boot one.
echo "display-mode — the preference is written permanently:"
CODE=$(sed 's|//.*||' "$APPLIER")
assert_contains "the completed configuration is permanent" "$CODE" \
  'CGCompleteDisplayConfiguration(configuration, .permanently)'

echo "display-mode — Swift typecheck:"
if command -v swiftc >/dev/null 2>&1; then
  if err=$(swiftc -typecheck "$APPLIER" 2>&1); then
    ok "applier typechecks"
  else
    bad "applier typechecks" "$err"
  fi

  # Both guards return before the first CoreGraphics call — see the header.
  echo "display-mode — argument validation (no display is touched):"
  assert_rc "no geometry → usage error"      64 swift "$APPLIER"
  assert_rc "unparseable geometry → refused" 64 swift "$APPLIER" 1920by1080
  assert_rc "zero geometry → refused"        64 swift "$APPLIER" 0x0
  assert_rc "too many arguments → refused"   64 swift "$APPLIER" 1920x1080 extra

  # The gate and the mode choice are pure functions, so the applier can decide
  # against measured fixtures with no display present. Asserting the literals
  # instead would prove nothing: `.permanently` and `1024x768` both appear in
  # this file's own comments, so a mutation of the executable code survives.
  echo "display-mode — decision selftest (fixtures, no display):"
  if selftest=$(swift -DSELFTEST "$APPLIER" 2>&1); then
    printf '%s\n' "$selftest" | grep -E '^  (ok|FAIL) ' | sed 's/^/  /'
    pass=$((pass + $(printf '%s' "$selftest" | grep -cE '^  ok ')))
  else
    bad "applier selftest" "$selftest"
  fi
else
  echo "  skip (no swiftc on this host — the applier only ever runs on macOS)"
fi

printf '\n  %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
