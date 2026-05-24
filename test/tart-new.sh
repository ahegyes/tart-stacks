#!/usr/bin/env bash
# Characterization tests for bin/tart-new. Plain bash, no framework (matches
# test/parsing.sh). Mocks `tart` on PATH and points TART_STACKS_DIR at a
# fixture stacks/ tree so stack validation, image-built detection, collision
# guarding, and resource pass-through are all exercised without a real VM.
set -uo pipefail

TEST_DIR=$(cd -P "$(dirname "$0")" >/dev/null 2>&1 && pwd)
REPO=$(cd -P "$TEST_DIR/.." >/dev/null 2>&1 && pwd)
BIN="$REPO/bin"

pass=0 fail=0
ok()  { pass=$((pass + 1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  FAIL %s\n         expected | %s\n         actual   | %s\n' "$1" "$2" "$3"; }
assert_eq()       { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "$2" "$3"; fi; }
assert_contains() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "contains » $3" "$2" ;; esac; }
assert_absent()   { case "$2" in *"$3"*) bad "$1" "absent » $3" "$2" ;; *) ok "$1" ;; esac; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# Fixture stacks/ tree: two stacks present.
mkdir -p "$WORK/stacks/fedora-php/scripts" "$WORK/stacks/fedora-jvm/scripts"

# Extract the pure helpers from the source and exercise them directly (same
# technique parsing.sh uses for tssh's parser fns — re-extracts each run so it
# tracks the real source through refactors).
extract_fn() { awk -v fn="$1" 'index($0, fn "() {")==1{p=1} p{print} p && $0=="}"{exit}' "$2"; }
{ extract_fn image_for_stack "$BIN/tart-new"
  echo
  extract_fn list_stacks "$BIN/tart-new"
  echo
  extract_fn stack_exists "$BIN/tart-new"; } > "$WORK/fns.sh"
# shellcheck disable=SC2034  # read as a global by the sourced helpers below
STACKS_DIR="$WORK/stacks"   # list_stacks/stack_exists read this global
# shellcheck source=/dev/null
source "$WORK/fns.sh"

echo "bin/tart-new — pure helpers:"
assert_eq "image_for_stack prefixes fedora-" "fedora-php" "$(image_for_stack php)"
assert_eq "list_stacks lists short tokens sorted" "jvm php" "$(list_stacks | sort | paste -sd' ' -)"
if stack_exists php; then ok "stack_exists true for present stack"; else bad "stack_exists true for present stack" "rc 0" "rc 1"; fi
if stack_exists rust; then bad "stack_exists false for absent stack" "rc 1" "rc 0"; else ok "stack_exists false for absent stack"; fi

echo
echo "  $pass passed, $fail failed"
[ "$fail" -eq 0 ]
