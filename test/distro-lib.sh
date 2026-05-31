#!/usr/bin/env bash
# Characterization test for distro-lib.sh _detect_family: os-release ID/ID_LIKE →
# family. Extracts the function from source (tracks it through refactors) and
# exercises it against synthetic os-release files. No framework.
set -uo pipefail
TEST_DIR=$(cd -P "$(dirname "$0")" >/dev/null 2>&1 && pwd); REPO=$(cd -P "$TEST_DIR/.." >/dev/null 2>&1 && pwd)
pass=0 fail=0
ok(){ pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad(){ fail=$((fail+1)); printf '  FAIL %s\n    exp|%s\n    got|%s\n' "$1" "$2" "$3"; }
assert_eq(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "$2" "$3"; fi; }
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
# Extract _detect_family and source it (same technique parsing.sh uses for tart-up fns).
awk 'index($0,"_detect_family() {")==1{p=1} p{print} p&&$0=="}"{exit}' "$REPO/shared/scripts/distro-lib.sh" > "$WORK/fn.sh"
# shellcheck source=/dev/null
source "$WORK/fn.sh"
echo "distro-lib — _detect_family:"
printf 'ID=fedora\n'                 > "$WORK/f"; assert_eq "fedora -> dnf"      dnf "$(OS_RELEASE=$WORK/f _detect_family)"
printf 'ID=ubuntu\nID_LIKE=debian\n' > "$WORK/u"; assert_eq "ubuntu -> apt"      apt "$(OS_RELEASE=$WORK/u _detect_family)"
printf 'ID=debian\n'                 > "$WORK/d"; assert_eq "debian -> apt"      apt "$(OS_RELEASE=$WORK/d _detect_family)"
printf 'ID=rhel\nID_LIKE=fedora\n'   > "$WORK/r"; assert_eq "rhel -> dnf"        dnf "$(OS_RELEASE=$WORK/r _detect_family)"
printf 'ID=arch\n'                   > "$WORK/a"; assert_eq "arch -> empty(rc1)" ""  "$(OS_RELEASE=$WORK/a _detect_family || true)"
echo; echo "  $pass passed, $fail failed"; [ "$fail" -eq 0 ]
