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
bad() { fail=$((fail + 1)); printf '  FAIL %s\n         %s\n' "$1" "${2:-}"; }
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

# ── membership_gate ─────────────────────────────────────────────────────────
# Three `php -m` fixtures, shaped exactly as PHP CLI prints them. The third is
# the regression test that matters: PHP writes an "Unable to load dynamic
# library" warning to the SAME stdout the extension list comes from, so an
# unanchored match reads the warning as proof the extension loaded and the gate
# passes the one failure it exists to catch.
echo "mise-lib — membership_gate:"

php_m_clean() {
  cat <<'EOF'
[PHP Modules]
bcmath
Core
imagick
json
mbstring
redis
Zend OPcache
zlib

[Zend Modules]
Xdebug
Zend OPcache
EOF
}

php_m_missing_imagick() {
  php_m_clean | grep -v '^imagick$'
}

# The exact shape of a broken ini: the warning precedes the listing, on stdout.
php_m_warning_polluted() {
  cat <<'EOF'

Warning: PHP Startup: Unable to load dynamic library 'imagick.so' (tried: /home/admin/.local/share/mise/installs/php/8.5.6/lib/php/extensions/no-debug-non-zts-20250925/imagick.so (cannot open shared object file: No such file or directory)) in Unknown on line 0
[PHP Modules]
bcmath
Core
json
mbstring
redis
Zend OPcache
zlib

[Zend Modules]
Zend OPcache
EOF
}

run_membership() { # <listing> <name…> — exit code in $rc, combined output in $OUT
  local listing="$1"; shift
  rc=0
  OUT=$( (membership_gate "PHP extensions" "$listing" "$@") 2>&1 ) || rc=$?
}

run_membership "$(php_m_clean)" bcmath imagick redis json
assert_eq       "all present → exit 0"         0 "$rc"
assert_contains "label printed"                "$OUT" "Smoke test (hard gate): PHP extensions"
assert_contains "each name reported loaded"    "$OUT" "imagick      loaded"

# Case-insensitive, because `php -m` spells opcache "Zend OPcache" — the reason
# the match cannot simply be exact.
run_membership "$(php_m_clean)" 'zend opcache'
assert_eq       "case-insensitive match → exit 0" 0 "$rc"

run_membership "$(php_m_missing_imagick)" bcmath imagick redis
assert_eq       "a genuinely absent extension → exit 1" 1 "$rc"
assert_contains "absent extension marked missing" "$OUT" "imagick      (missing)"
assert_contains "count reported"                  "$OUT" "1 of the expected PHP extensions did not load"
assert_contains "present siblings still reported" "$OUT" "bcmath       loaded"

run_membership "$(php_m_warning_polluted)" bcmath imagick redis
assert_eq       "warning-polluted stdout → exit 1" 1 "$rc"
assert_contains "the warning is not read as the extension" "$OUT" "imagick      (missing)"
# The needle appears inside the warning text, which is exactly why the match has
# to be line-anchored rather than a containment test.
assert_contains "the warning really does carry the name" "$(php_m_warning_polluted)" "imagick.so"

printf '\n  %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
