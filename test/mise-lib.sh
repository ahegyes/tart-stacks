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

# Same, but under the shell options the real caller sets. mise-install.sh runs
# with `set -euo pipefail`, and that is what turns a stray pipeline 141 into an
# aborted build — without it a broken gate looks like it passed.
run_gate_strict() { # args... — exit code in $rc, combined output in $OUT
  rc=0
  OUT=$( ( set -eo pipefail; smoke_gate "$@" ) 2>&1 ) || rc=$?
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

# The same SIGPIPE shape membership_gate carries: awk exits at the first match, so
# past the pipe buffer the producer takes SIGPIPE and pipefail turns a PASSING
# check into 141 — and here it is not inside an `if`, so the caller's `set -e`
# aborts the build with nothing printed.
# shellcheck disable=SC2016  # $i is the inner sh's loop counter, not this shell's
run_gate_strict "bulky" -- sh -c 'i=0; while [ $i -lt 20000 ]; do printf "line%06d\n" $i; i=$((i+1)); done'
assert_eq       "a command with output past the pipe buffer → exit 0" 0 "$rc"
assert_contains "its first line is still reported" "$OUT" "line000000"

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

# A listing past the 64 KiB pipe buffer with the needle on the FIRST line: read
# through `printf | grep -q`, grep exits at the match, printf takes SIGPIPE, and
# pipefail reports 141 — so a name that IS there reads as missing.
big_listing() {
  printf '[PHP Modules]\nimagick\n'
  local i=0
  while [ "$i" -lt 20000 ]; do printf 'filler%06d\n' "$i"; i=$((i + 1)); done
}
BIG="$(big_listing)"
if [ "${#BIG}" -gt 65536 ]; then
  ok "the large-listing fixture exceeds the pipe buffer (${#BIG} bytes)"
else
  bad "the large-listing fixture exceeds the pipe buffer" "only ${#BIG} bytes — too small to expose a SIGPIPE read"
fi
run_membership "$BIG" imagick
assert_eq       "a match early in a large listing → exit 0" 0 "$rc"
assert_contains "a match early in a large listing is reported loaded" "$OUT" "imagick      loaded"

run_membership "$(php_m_warning_polluted)" bcmath imagick redis
assert_eq       "warning-polluted stdout → exit 1" 1 "$rc"
assert_contains "the warning is not read as the extension" "$OUT" "imagick      (missing)"
# The needle appears inside the warning text, which is exactly why the match has
# to be line-anchored rather than a containment test.
assert_contains "the warning really does carry the name" "$(php_m_warning_polluted)" "imagick.so"

# ── the gates are WIRED, not merely correct ────────────────────────────────
# Everything above proves the gates behave. Nothing above proves anything ever
# CALLS them: both gate calls could be deleted from every provisioner and this
# file would stay green, shipping an image with no extension check at all —
# the opposite of the hard-gate contract AGENTS.md states. These assertions are
# static because the gates only ever run inside a real build, and they walk the
# tree rather than a hand-listed set so a stack added later is covered by
# construction. Same technique test/finalize-linux.sh uses for its own wiring.
echo
echo "mise-lib — every stack's provisioner actually calls the gates:"
shopt -s nullglob
installers=(stacks/*/scripts/*/mise-install.sh templates/stack/scripts/*/mise-install.sh.tmpl)
if [ "${#installers[@]}" -eq 0 ]; then
  bad "found provisioners to check" "no mise-install.sh under stacks/*/scripts/*/"
else
  ok "found ${#installers[@]} provisioners to check"
fi
for inst in "${installers[@]}"; do
  label="${inst#stacks/}"; label="${label#templates/stack/}"
  if grep -q 'mise-lib\.sh' "$inst"; then
    ok "$label sources mise-lib.sh"
  else
    bad "$label sources mise-lib.sh" "no reference found"
  fi
  if grep -qE '^smoke_gate ' "$inst"; then
    ok "$label calls smoke_gate"
  else
    bad "$label calls smoke_gate" "no call found — the runtime check would not run"
  fi
done
# php is the stack whose README advertises a fixed extension set, so its
# membership_gate call is part of that promise rather than optional.
for inst in stacks/php/scripts/*/mise-install.sh; do
  if grep -qE '^membership_gate ' "$inst"; then
    ok "${inst#stacks/} calls membership_gate"
  else
    bad "${inst#stacks/} calls membership_gate" "no call found — PHP extensions would go unchecked"
  fi
done

printf '\n  %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
