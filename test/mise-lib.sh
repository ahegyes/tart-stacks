#!/usr/bin/env bash
# Characterization tests for shared/scripts/mise-lib.sh's smoke_gate: the
# `--`-delimited argv-group grammar, word-split safety of arguments, the
# FAILED path's count + hard exit, and empty-group tolerance. The lib is
# function-definitions-only, so sourcing it is side-effect free; each gate run
# happens in a subshell because a failing gate exits the shell that ran it.
# mise_runtime_setup is NOT driven here — it calls the real mise and is proven
# by an image rebuild. Plain bash, no framework. Run via script/test or directly.
set -uo pipefail

TEST_DIR=$(cd -P "$(dirname "$0")" >/dev/null 2>&1 && pwd)
REPO=$(cd -P "$TEST_DIR/.." >/dev/null 2>&1 && pwd)

pass=0 fail=0
ok()  { pass=$((pass + 1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  FAIL %s\n         %s\n' "$1" "$2"; }
assert_eq()       { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "want » $2 « got » $3 «"; fi; }
assert_contains() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "want » $3 « in: $2" ;; esac; }
assert_absent()   { case "$2" in *"$3"*) bad "$1" "should NOT contain » $3 «" ;; *) ok "$1" ;; esac; }

WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT

# shellcheck source=shared/scripts/mise-lib.sh
. "$REPO/shared/scripts/mise-lib.sh"

run_gate() { # args... — exit code in $rc, combined output in $OUT
  rc=0
  OUT=$( (smoke_gate "$@") 2>&1 ) || rc=$?
}

echo "mise-lib — smoke_gate:"

run_gate "happy" -- echo hello -- printf 'world\n'
assert_eq       "all groups pass → exit 0" 0 "$rc"
assert_contains "label printed"            "$OUT" "Smoke test (hard gate): happy"
assert_contains "first group's output"     "$OUT" "hello"
assert_contains "second group's output"    "$OUT" "world"

# Argv groups must survive arguments with spaces — the property the grammar
# exists for (a string API would word-split these).
# shellcheck disable=SC2016  # $1/$2 are for the inner sh, not this shell
run_gate "spacing" -- sh -c 'printf "%s|%s\n" "$1" "$2"' _ "a b" "c d"
assert_eq       "spaced args → exit 0"          0 "$rc"
assert_contains "spaced args arrive unsplit"    "$OUT" "a b|c d"

run_gate "failing" -- echo fine -- sh -c 'echo boom >&2; exit 3'
assert_eq       "a failing group → exit 1"         1 "$rc"
assert_contains "failing group marked FAILED"      "$OUT" "FAILED"
assert_contains "failing group's stderr surfaced"  "$OUT" "boom"
assert_contains "failure count reported"           "$OUT" "1 check(s) failed in 'failing'"
assert_contains "passing sibling still ran"        "$OUT" "fine"

run_gate "empties" -- -- echo solo -- --
assert_eq       "doubled/trailing -- ignored" 0 "$rc"
assert_contains "real group still ran"        "$OUT" "solo"
assert_absent   "no empty-group FAILED noise" "$OUT" "FAILED"

printf '\n  %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
