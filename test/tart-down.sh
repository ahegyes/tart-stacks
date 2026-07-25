#!/usr/bin/env bash
# Characterization tests for bin/tart-down: the deliberate-stop mark and the
# stop it guards. `tart` is mocked (list answers from $MOCK_TART_LIST_JSON, stop
# outcome from $MOCK_TART_STOP_RC) and the state dir is redirected into a
# tmpdir, so no real VM is touched. Covers the mark/stop ordering, the
# already-stopped and failed-stop paths, name resolution, and the base-image
# refusal. Plain bash, no framework. Run via script/test or directly.
set -uo pipefail

TEST_DIR=$(cd -P "$(dirname "$0")" >/dev/null 2>&1 && pwd)
REPO=$(cd -P "$TEST_DIR/.." >/dev/null 2>&1 && pwd)
BIN="$REPO/bin"

pass=0 fail=0
ok()  { pass=$((pass + 1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  FAIL %s\n         %s\n' "$1" "$2"; }
assert_contains() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "want » $3 « in: $2" ;; esac; }
assert_absent()   { case "$2" in *"$3"*) bad "$1" "should NOT contain » $3 «" ;; *) ok "$1" ;; esac; }
assert_file()     { if [ -e "$2" ]; then ok "$1"; else bad "$1" "missing file: $2"; fi; }
assert_no_file()  { if [ -e "$2" ]; then bad "$1" "unexpected file: $2"; else ok "$1"; fi; }
assert_rc()       { if [ "$3" -eq "$2" ]; then ok "$1"; else bad "$1" "want rc=$2 got rc=$3"; fi; }
assert_eq()       { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "want » $2 « got » $3 «"; fi; }

WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
MOCKBIN="$WORK/bin"; mkdir -p "$MOCKBIN"
CALLS="$WORK/calls"; export CALLS
STATE="$WORK/state"
MARKS="$STATE/stopped"

# Fixtures the base-image guard reads: one stack, one distro, one desktop, so
# `fedora-php` and `fedora-php-kde` resolve as base images and `app-a` does not.
mkdir -p "$WORK/stacks/php"
printf 'fedora\n' > "$WORK/distros"
printf 'kde\n'    > "$WORK/desktops"

cat > "$MOCKBIN/tart" <<'M'
#!/usr/bin/env bash
echo "tart $*" >> "$CALLS"
if [ "${1:-}" = "list" ]; then printf '%s' "${MOCK_TART_LIST_JSON:-[]}"; exit 0; fi
if [ "${1:-}" = "stop" ]; then exit "${MOCK_TART_STOP_RC:-0}"; fi
exit 0
M
chmod +x "$MOCKBIN/tart"

LIST_RUNNING='[{"Name":"app-a","State":"running"},{"Name":"fedora-php","State":"stopped"}]'

run_down() { # <args...>  -> stdout+stderr in $OUT, exit code in $rc
  : > "$CALLS"
  rc=0
  OUT=$(PATH="$MOCKBIN:$PATH" \
    MOCK_TART_LIST_JSON="${MOCK_TART_LIST_JSON:-$LIST_RUNNING}" \
    MOCK_TART_STOP_RC="${MOCK_TART_STOP_RC:-0}" \
    TART_STATE_DIR="$STATE" \
    TART_STACKS_DIR="$WORK/stacks" TART_DISTROS="$WORK/distros" TART_DESKTOPS="$WORK/desktops" \
    bash "$BIN/tart-down" "$@" 2>&1) || rc=$?
}

echo "bin/tart-down — argument handling:"
run_down;        assert_rc "no args → exit 64"   64 "$rc"
run_down a b;    assert_rc "two args → exit 64"  64 "$rc"
run_down --help; assert_rc "--help → exit 0"      0 "$rc"
run_down nope;   assert_rc "unknown vm → exit 1"  1 "$rc"
assert_contains "unknown bare vm names requested form" "$OUT" "VM 'nope' not found."
assert_absent   "unknown bare vm claims no second form" "$OUT" "also tried"
run_down tart-nope
assert_rc       "unknown prefixed vm → exit 1" 1 "$rc"
assert_contains "unknown prefixed vm names stripped form" "$OUT" "also tried 'nope'"

# The alias namespace can contain out-of-band VMs created with raw `tart`, but
# a bare tart-stacks name must never resolve forward into that namespace.
rm -rf "$MARKS"
MOCK_TART_LIST_JSON='[{"Name":"tart-nope","State":"running"}]' run_down nope
assert_rc     "bare miss ignores literal tart-prefixed vm" 1 "$rc"
calls=$(cat "$CALLS")
assert_eq     "bare miss performs only its as-given state probe" 1 "$(grep -c '^tart list --format json$' "$CALLS")"
assert_absent "bare miss does not stop tart-prefixed vm" "$calls" "tart stop tart-nope"
assert_no_file "bare miss does not mark tart-prefixed vm" "$MARKS/tart-nope"

echo "bin/tart-down — the mark and the stop:"
rm -rf "$MARKS"
run_down app-a
assert_rc "running vm → exit 0" 0 "$rc"
assert_file     "writes the deliberate-stop mark" "$MARKS/app-a"
assert_contains "stops the vm"                    "$(cat "$CALLS")" "tart stop app-a"
assert_contains "explains how the mark clears"    "$OUT" "clears the mark"

# The prefixed form resolves to the same bare VM, so the mark cannot end up
# under a second name that the supervisor never checks.
rm -rf "$MARKS"
run_down tart-app-a
assert_file    "prefixed form marks the bare name" "$MARKS/app-a"
assert_no_file "prefixed form leaves no alias mark" "$MARKS/tart-app-a"

# `tart stop` fails on an already-stopped VM. The intent is still recorded, and
# that is not an error — holding a stopped VM down is a legitimate request.
rm -rf "$MARKS"
MOCK_TART_LIST_JSON='[{"Name":"app-a","State":"stopped"}]' MOCK_TART_STOP_RC=1 run_down app-a
assert_rc "already-stopped vm → exit 0" 0 "$rc"
assert_file "already-stopped vm is still marked" "$MARKS/app-a"

# A stop that fails while the VM stays running IS an error — but the mark must
# stand, or the supervisor would restart the VM the operator just asked to stop.
rm -rf "$MARKS"
MOCK_TART_STOP_RC=1 run_down app-a
assert_rc "failed stop of a running vm → exit 1" 1 "$rc"
assert_file     "failed stop still leaves the mark" "$MARKS/app-a"
assert_contains "failed stop says the mark stands" "$OUT" "mark stands"

echo "bin/tart-down — base-image refusal:"
rm -rf "$MARKS"
MOCK_TART_LIST_JSON='[{"Name":"fedora-php","State":"stopped"}]' run_down fedora-php
assert_rc "base image → exit 1" 1 "$rc"
assert_absent  "base image is not stopped" "$(cat "$CALLS")" "tart stop"
assert_no_file "base image is not marked"  "$MARKS/fedora-php"

echo; echo "  $pass passed, $fail failed"; [ "$fail" -eq 0 ]
