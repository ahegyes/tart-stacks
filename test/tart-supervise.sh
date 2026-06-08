#!/usr/bin/env bash
# Characterization tests for bin/tart-supervise. Mocks tart / tart-up / pgrep /
# launchctl so no real VM, process, or LaunchAgent is touched: pgrep liveness is
# driven by $MOCK_ALIVE, and the LaunchAgent dir + logs are redirected into a
# tmpdir. Covers the --once restart cycle (down vs already-up), and install /
# uninstall / status LaunchAgent wiring. Plain bash, no framework. Run via
# script/test or directly.
set -uo pipefail

TEST_DIR=$(cd -P "$(dirname "$0")" >/dev/null 2>&1 && pwd)
REPO=$(cd -P "$TEST_DIR/.." >/dev/null 2>&1 && pwd)
BIN="$REPO/bin"

pass=0 fail=0
ok()  { pass=$((pass + 1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  FAIL %s\n         %s\n' "$1" "$2"; }
assert_contains() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "want » $3 « in: $2" ;; esac; }
assert_absent()   { case "$2" in *"$3"*) bad "$1" "should NOT contain » $3 «" ;; *) ok "$1" ;; esac; }
check_rc() { local l="$1" want="$2"; shift 2; local got=0; "$@" >/dev/null 2>&1 || got=$?
  if [ "$got" -eq "$want" ]; then ok "$l"; else bad "$l" "want rc=$want got rc=$got"; fi; }

WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
MOCKBIN="$WORK/bin"; mkdir -p "$MOCKBIN"
CALLS="$WORK/calls"; export CALLS

# Mocks: every call is logged to $CALLS. `ps` drives liveness — MOCK_PS_LINE sets
# the `tart run` cmdline vm_alive's awk scans, else MOCK_ALIVE=1 emits a standard
# one. `tart-up`, `tart`, `launchctl` just record and succeed. Bodies are quoted
# heredocs — their $* / $CALLS are literal, expanded when the mock runs.
cat > "$MOCKBIN/tart"      <<'M'
#!/usr/bin/env bash
echo "tart $*" >> "$CALLS"
exit 0
M
cat > "$MOCKBIN/tart-up"   <<'M'
#!/usr/bin/env bash
echo "tart-up $*" >> "$CALLS"
exit 0
M
cat > "$MOCKBIN/launchctl" <<'M'
#!/usr/bin/env bash
echo "launchctl $*" >> "$CALLS"
exit 0
M
cat > "$MOCKBIN/ps"        <<'M'
#!/usr/bin/env bash
# vm_alive runs `ps -axo args=`; emit a `tart run` cmdline for it to scan.
if [ -n "${MOCK_PS_LINE:-}" ]; then
  printf '%s\n' "$MOCK_PS_LINE"
elif [ "${MOCK_ALIVE:-0}" = "1" ]; then
  printf '%s\n' "/opt/tart.app/Contents/MacOS/tart run ${MOCK_VM:-app-a} --no-graphics"
fi
exit 0
M
chmod +x "$MOCKBIN"/tart "$MOCKBIN"/tart-up "$MOCKBIN"/launchctl "$MOCKBIN"/ps

LA="$WORK/la"; LOGS="$WORK/logs"
run_sup() { # <MOCK_ALIVE> <args...>
  : > "$CALLS"
  local alive="$1"; shift
  PATH="$MOCKBIN:$PATH" MOCK_ALIVE="$alive" \
    TART_LAUNCHAGENTS_DIR="$LA" TART_LOG_DIR="$LOGS" \
    bash "$BIN/tart-supervise" "$@"
}

# argument validation
check_rc "no args → exit 64"          64 env PATH="$MOCKBIN:$PATH" bash "$BIN/tart-supervise"
check_rc "--once needs a vm → exit 64" 64 env PATH="$MOCKBIN:$PATH" bash "$BIN/tart-supervise" --once
check_rc "--install needs a vm → 64"   64 env PATH="$MOCKBIN:$PATH" bash "$BIN/tart-supervise" --install
check_rc "--help → exit 0"             0  env PATH="$MOCKBIN:$PATH" bash "$BIN/tart-supervise" --help

# --once on a DOWN vm: clears wedged state (tart stop) then starts via tart-up
run_sup 0 --once app-a >/dev/null 2>&1
calls="$(cat "$CALLS")"
assert_contains "down → clears wedged state (tart stop)" "$calls" "tart stop app-a"
assert_contains "down → restarts via tart-up"            "$calls" "tart-up app-a"

# --once on an ALREADY-UP vm: no stop, no start (idempotent)
run_sup 1 --once app-a >/dev/null 2>&1
calls="$(cat "$CALLS")"
assert_absent "up → no tart stop" "$calls" "tart stop"
assert_absent "up → no tart-up"   "$calls" "tart-up"

# prefix form is accepted and normalized to the bare name
run_sup 0 --once tart-app-a >/dev/null 2>&1
assert_contains "prefix form normalized to bare name" "$(cat "$CALLS")" "tart-up app-a"

# liveness is flag-order independent: options-before-name (the form `tart run
# --help` documents) still counts as up, so no needless restart.
: > "$CALLS"
PATH="$MOCKBIN:$PATH" MOCK_PS_LINE="/o/tart run --no-graphics app-a" \
  TART_LAUNCHAGENTS_DIR="$LA" TART_LOG_DIR="$LOGS" bash "$BIN/tart-supervise" --once app-a >/dev/null 2>&1
assert_absent "liveness: option-before-name counts as up (no restart)" "$(cat "$CALLS")" "tart-up"

# liveness is whole-argument: a different VM whose name extends ours is NOT us.
: > "$CALLS"
PATH="$MOCKBIN:$PATH" MOCK_PS_LINE="/o/tart run app-a-2 --no-graphics" \
  TART_LAUNCHAGENTS_DIR="$LA" TART_LOG_DIR="$LOGS" bash "$BIN/tart-supervise" --once app-a >/dev/null 2>&1
assert_contains "liveness: app-a-2 is not app-a → restart fires" "$(cat "$CALLS")" "tart-up app-a"

# --install writes a LaunchAgent and loads it
run_sup 0 --install app-a >/dev/null 2>&1
plist="$LA/com.tart-stacks.supervise.app-a.plist"
if [ -f "$plist" ]; then ok "install → plist written"; else bad "install → plist written" "missing $plist"; fi
pl="$(cat "$plist" 2>/dev/null)"
assert_contains "plist sets the per-VM label"        "$pl" "<string>com.tart-stacks.supervise.app-a</string>"
assert_contains "plist runs this script with the vm"  "$pl" "/bin/tart-supervise</string>"
assert_contains "plist passes the vm as an argument"  "$pl" "<string>app-a</string>"
assert_contains "plist bakes a PATH with tart's dir"  "$pl" "$MOCKBIN"
assert_contains "plist keeps the supervisor alive"    "$pl" "<key>KeepAlive</key>"
assert_contains "install loads via launchctl bootstrap" "$(cat "$CALLS")" "launchctl bootstrap"

# --status lists the installed supervisor (mock launchctl print → loaded)
run_sup 0 --status app-a > "$WORK/status.out" 2>/dev/null
assert_contains "status names the supervised vm" "$(cat "$WORK/status.out")" "app-a"

# --uninstall unloads and removes the plist
run_sup 0 --uninstall app-a >/dev/null 2>&1
assert_contains "uninstall unloads via launchctl bootout" "$(cat "$CALLS")" "launchctl bootout"
if [ -f "$plist" ]; then bad "uninstall → plist removed" "still present: $plist"; else ok "uninstall → plist removed"; fi

printf '\n  %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
