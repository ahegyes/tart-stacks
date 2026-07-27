#!/usr/bin/env bash
# Characterization tests for bin/tart-down — a safe wrapper over `tart stop`.
# `tart` is a PATH mock (list answers from $MOCK_TART_LIST_JSON, stop outcome
# from $MOCK_TART_STOP_RC), so no VM is touched. Covers arity, alias-prefix
# resolution, the base-image refusal, and the already-stopped vs failed-stop
# split. Plain bash, no framework. Run via script/test or directly.
set -uo pipefail

TEST_DIR=$(cd -P "$(dirname "$0")" >/dev/null 2>&1 && pwd)
REPO=$(cd -P "$TEST_DIR/.." >/dev/null 2>&1 && pwd)
BIN="$REPO/bin"

pass=0 fail=0
ok()  { pass=$((pass + 1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  FAIL %s\n         %s\n' "$1" "${2:-}"; }
assert_contains() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "want » $3 « in: $2" ;; esac; }
assert_absent()   { case "$2" in *"$3"*) bad "$1" "should NOT contain » $3 «" ;; *) ok "$1" ;; esac; }
assert_rc()       { if [ "$rc" -eq "$2" ]; then ok "$1"; else bad "$1" "want rc=$2 got rc=$rc"; fi; }

WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
MOCKBIN="$WORK/bin"; mkdir -p "$MOCKBIN"
CALLS="$WORK/calls"; export CALLS

# Fixtures the base-image guard reads: fedora is a distro, php a stack, kde a
# desktop — so fedora-php and fedora-php-kde are base images and app-a is not.
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

LIST='[{"Name":"app-a","Source":"local","State":"running"},{"Name":"fedora-php","Source":"local","State":"stopped"}]'

run_down() { # <args...> -> combined output in $OUT, exit code in $rc
  : > "$CALLS"; rc=0
  OUT=$(PATH="$MOCKBIN:$PATH" \
    MOCK_TART_LIST_JSON="${MOCK_TART_LIST_JSON:-$LIST}" \
    MOCK_TART_STOP_RC="${MOCK_TART_STOP_RC:-0}" \
    TART_STACKS_DIR="$WORK/stacks" TART_OS_FILE="$WORK/distros" TART_DESKTOPS="$WORK/desktops" \
    bash "$BIN/tart-down" "$@" 2>&1) || rc=$?
}

echo "bin/tart-down — argument handling:"
run_down;       assert_rc "no args → exit 64"  64
run_down a b;   assert_rc "two args → exit 64" 64
run_down --help; assert_rc "--help → exit 0"   0

echo "bin/tart-down — resolution:"
run_down app-a
assert_rc       "running VM → exit 0" 0
assert_contains "running VM → stop issued" "$OUT" "'app-a' stopped."
assert_contains "stop targets the bare name" "$(cat "$CALLS")" "tart stop app-a"

# The SSH alias form resolves to the stored bare name; the prefix is never
# passed through to tart.
run_down tart-app-a
assert_rc       "alias form → exit 0" 0
assert_contains "alias form → stops the bare VM" "$(cat "$CALLS")" "tart stop app-a"
assert_absent   "alias form → never stops the prefixed name" "$(cat "$CALLS")" "tart stop tart-app-a"

run_down nope
assert_rc       "unknown VM → exit 1" 1
assert_contains "unknown VM → names the form checked" "$OUT" "VM 'nope' not found."
assert_absent   "unknown VM → nothing stopped" "$(cat "$CALLS")" "tart stop"

echo "bin/tart-down — refusals and failure modes:"
# Base images are clone sources; stopping one is always a mistyped name.
run_down fedora-php
assert_rc       "base image → exit 1" 1
assert_contains "base image → says why" "$OUT" "base image"
assert_absent   "base image → nothing stopped" "$(cat "$CALLS")" "tart stop"

# `tart stop` fails on an already-stopped VM, which IS the requested end state.
MOCK_TART_LIST_JSON='[{"Name":"app-a","Source":"local","State":"stopped"}]' \
  MOCK_TART_STOP_RC=1 run_down app-a
assert_rc       "already stopped → exit 0" 0
assert_contains "already stopped → says so" "$OUT" "was already stopped"

# A stop that fails while the VM is still running is a real failure.
MOCK_TART_STOP_RC=1 run_down app-a
assert_rc       "failed stop of a running VM → exit 1" 1
assert_contains "failed stop → reports it" "$OUT" "still running"

echo
echo "  $pass passed, $fail failed"
[ "$fail" -eq 0 ]
