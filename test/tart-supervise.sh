#!/usr/bin/env bash
# Characterization tests for bin/tart-supervise. Mocks tart / tart-up / ps /
# launchctl so no real VM, process, or LaunchAgent is touched: ps liveness is
# driven by $MOCK_ALIVE / $MOCK_PS_LINE, `tart list` answers come from
# $MOCK_TART_LIST_JSON (failure via $MOCK_TART_LIST_RC), and the LaunchAgent
# dir + logs are redirected into a tmpdir. Covers the --once restart cycle
# (down vs already-up), the install validation gates (missing VM / base image
# / failing list), the plist contract (KeepAlive dict + AbandonProcessGroup),
# uninstall's supervision-only semantics, the deleted-VM terminal path of the
# foreground loop, and the --status columns. Plain bash, no framework. Run via
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
# the `tart run` cmdline tart_vm_alive's awk scans, else MOCK_ALIVE=1 emits a standard
# one. `tart` answers `list` from $MOCK_TART_LIST_JSON, or fails with
# $MOCK_TART_LIST_RC (stderr marker first, mirroring test/tart-up.sh); other
# subcommands just record. `tart-up` and `launchctl` record and succeed.
# Bodies are quoted heredocs — their $* / $CALLS are literal, expanded when
# the mock runs.
cat > "$MOCKBIN/tart"      <<'M'
#!/usr/bin/env bash
echo "tart $*" >> "$CALLS"
if [ "${1:-}" = "list" ]; then
  # MOCK_TART_LIST_SEQ serves one file line per `list` call (last line repeats
  # once exhausted) — for tests that need the answer to CHANGE across polls.
  if [ -n "${MOCK_TART_LIST_SEQ:-}" ] && [ -f "$MOCK_TART_LIST_SEQ" ]; then
    n=$(cat "${MOCK_TART_LIST_SEQ}.idx" 2>/dev/null || echo 1)
    line=$(sed -n "${n}p" "$MOCK_TART_LIST_SEQ")
    [ -n "$line" ] || line=$(tail -n 1 "$MOCK_TART_LIST_SEQ")
    echo $((n + 1)) > "${MOCK_TART_LIST_SEQ}.idx"
    printf '%s\n' "$line"
    exit 0
  fi
  if [ "${MOCK_TART_LIST_RC:-0}" -ne 0 ]; then
    echo "MOCK_TART_LIST_STDERR_MARKER" >&2
    exit "${MOCK_TART_LIST_RC}"
  fi
  printf '%s\n' "${MOCK_TART_LIST_JSON:-[]}"
fi
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
# tart_vm_alive runs `ps -axo args=`; emit a `tart run` cmdline for it to scan.
if [ -n "${MOCK_PS_LINE:-}" ]; then
  printf '%s\n' "$MOCK_PS_LINE"
elif [ "${MOCK_ALIVE:-0}" = "1" ]; then
  printf '%s\n' "/opt/tart.app/Contents/MacOS/tart run ${MOCK_VM:-app-a} --no-graphics"
fi
exit 0
M
chmod +x "$MOCKBIN"/tart "$MOCKBIN"/tart-up "$MOCKBIN"/launchctl "$MOCKBIN"/ps

LA="$WORK/la"; LOGS="$WORK/logs"

# Fixture stacks/ + distros + desktops for the --install base-image gate (same
# shape as test/tart-new.sh): fedora is supported, php is a stack →
# fedora-php is base.
mkdir -p "$WORK/stacks/php"
printf 'fedora\n' > "$WORK/distros"
printf 'kde\n' > "$WORK/desktops"

# Default `tart list` answer: app-a exists — the install/status happy paths
# rely on it; validation tests override per call via an env prefix.
LIST_DEFAULT='[{"Name":"app-a","Source":"local","State":"running"}]'

run_sup() { # <MOCK_ALIVE> <args...>
  : > "$CALLS"
  local alive="$1"; shift
  PATH="$MOCKBIN:$PATH" MOCK_ALIVE="$alive" \
    MOCK_TART_LIST_JSON="${MOCK_TART_LIST_JSON:-$LIST_DEFAULT}" \
    MOCK_TART_LIST_RC="${MOCK_TART_LIST_RC:-0}" \
    TART_LAUNCHAGENTS_DIR="$LA" TART_LOG_DIR="$LOGS" \
    TART_STACKS_DIR="$WORK/stacks" TART_DISTROS="$WORK/distros" TART_DESKTOPS="$WORK/desktops" \
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

# canonical shape (vm right after run, then flags/mounts) counts as up — no restart.
: > "$CALLS"
PATH="$MOCKBIN:$PATH" MOCK_PS_LINE="/o/MacOS/tart run app-a --no-graphics --dir=/x:ro" \
  TART_LAUNCHAGENTS_DIR="$LA" TART_LOG_DIR="$LOGS" bash "$BIN/tart-supervise" --once app-a >/dev/null 2>&1
assert_absent "liveness: canonical shape is up (no restart)" "$(cat "$CALLS")" "tart-up"

# a token inside ANOTHER VM's spaced --dir path must NOT read as our VM being up
# (anchoring <vm> to the post-run position prevents that false positive).
: > "$CALLS"
PATH="$MOCKBIN:$PATH" MOCK_PS_LINE="/o/MacOS/tart run appfoo --dir=/x/Project app-a Data:ro" \
  TART_LAUNCHAGENTS_DIR="$LA" TART_LOG_DIR="$LOGS" bash "$BIN/tart-supervise" --once app-a >/dev/null 2>&1
assert_contains "liveness: app-a inside another VM's --dir is not up → restart" "$(cat "$CALLS")" "tart-up app-a"

# a different VM whose name extends ours is not us (whole-argument match).
: > "$CALLS"
PATH="$MOCKBIN:$PATH" MOCK_PS_LINE="/o/MacOS/tart run app-a-2 --no-graphics" \
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
assert_contains "plist KeepAlive honors a clean exit (SuccessfulExit dict)" "$pl" "<dict><key>SuccessfulExit</key><false/></dict>"
assert_absent   "plist KeepAlive is not the unconditional form"             "$pl" "<key>KeepAlive</key><true/>"
assert_contains "plist abandons the process group (bootout ≠ VM kill)"      "$pl" "<key>AbandonProcessGroup</key><true/>"
assert_contains "install loads via launchctl bootstrap" "$(cat "$CALLS")" "launchctl bootstrap"

# ── --install validation gates ───────────────────────────────────────────────
# Missing VM: refuse before any side effect — no plist, error names the VM and
# the remedies.
rc=0; MOCK_TART_LIST_JSON='[]' run_sup 0 --install ghost >/dev/null 2>"$WORK/err" || rc=$?
if [ "$rc" -eq 1 ]; then ok "install missing VM → exit 1"; else bad "install missing VM → exit 1" "want rc=1 got rc=$rc"; fi
if [ -f "$LA/com.tart-stacks.supervise.ghost.plist" ]; then bad "install missing VM → no plist written" "plist exists"; else ok "install missing VM → no plist written"; fi
assert_contains "install missing VM → names the VM"       "$(cat "$WORK/err")" "VM 'ghost' not found"
assert_contains "install missing VM → points at tart-new" "$(cat "$WORK/err")" "tart-new"

# Base image: a supervised base would loop forever on tart-up's clone-source
# refusal — refuse at install time instead.
rc=0; MOCK_TART_LIST_JSON='[{"Name":"fedora-php","Source":"local","State":"stopped"}]' \
  run_sup 0 --install fedora-php >/dev/null 2>"$WORK/err" || rc=$?
if [ "$rc" -eq 1 ]; then ok "install base image → exit 1"; else bad "install base image → exit 1" "want rc=1 got rc=$rc"; fi
if [ -f "$LA/com.tart-stacks.supervise.fedora-php.plist" ]; then bad "install base image → no plist written" "plist exists"; else ok "install base image → no plist written"; fi
assert_contains "install base image → says base image" "$(cat "$WORK/err")" "base image"

# Failing `tart list` is a broken tool, not a missing VM: distinct error, no plist.
rc=0; MOCK_TART_LIST_RC=1 run_sup 0 --install app-b >/dev/null 2>"$WORK/err" || rc=$?
if [ "$rc" -eq 1 ]; then ok "install w/ failing list → exit 1"; else bad "install w/ failing list → exit 1" "want rc=1 got rc=$rc"; fi
if [ -f "$LA/com.tart-stacks.supervise.app-b.plist" ]; then bad "install w/ failing list → no plist written" "plist exists"; else ok "install w/ failing list → no plist written"; fi
assert_contains "install w/ failing list → names the tool"          "$(cat "$WORK/err")" "'tart list' failed"
assert_contains "install w/ failing list → tart's stderr surfaced"  "$(cat "$WORK/err")" "MOCK_TART_LIST_STDERR_MARKER"
assert_absent   "install w/ failing list → not read as missing VM"  "$(cat "$WORK/err")" "not found"

# --status lists the installed supervisor (mock launchctl print → loaded)
run_sup 0 --status app-a > "$WORK/status.out" 2>/dev/null
assert_contains "status names the supervised vm" "$(cat "$WORK/status.out")" "app-a"

# ── --status diagnostic columns ──────────────────────────────────────────────
# One row per supervised VM: agent state, VM presence from one shared
# `tart list`, process liveness. ghost has an agent but no VM → vm:MISSING.
printf 'seed\n' > "$LA/com.tart-stacks.supervise.ghost.plist"
run_sup 1 --status > "$WORK/status2.out" 2>/dev/null
row_a=$(grep '^app-a' "$WORK/status2.out")
row_g=$(grep '^ghost' "$WORK/status2.out")
assert_contains "status row: healthy VM shows agent loaded" "$row_a" "loaded"
assert_contains "status row: healthy VM shows vm:running"   "$row_a" "vm:running"
assert_contains "status row: healthy VM shows proc:alive"   "$row_a" "proc:alive"
assert_contains "status row: deleted VM shows vm:MISSING"   "$row_g" "vm:MISSING"
assert_contains "status row: deleted VM shows proc:-"       "$row_g" "proc:-"

# A failing `tart list` degrades the vm column to `?` (one stderr note); the
# report itself still succeeds.
rc=0; MOCK_TART_LIST_RC=1 run_sup 0 --status app-a > "$WORK/status3.out" 2>"$WORK/status3.err" || rc=$?
if [ "$rc" -eq 0 ]; then ok "status survives a failing tart list (rc 0)"; else bad "status survives a failing tart list (rc 0)" "want rc=0 got rc=$rc"; fi
assert_contains "status degrades to vm:? on list failure" "$(cat "$WORK/status3.out")" "vm:?"
assert_contains "status notes the failed list on stderr"  "$(cat "$WORK/status3.err")" "'tart list' failed"
rm -f "$LA/com.tart-stacks.supervise.ghost.plist"

# --uninstall unloads and removes the plist — supervision only: the VM is left
# running (no tart stop), and the message says how to stop/delete it.
run_sup 0 --uninstall app-a >/dev/null 2>"$WORK/err"
calls="$(cat "$CALLS")"
assert_contains "uninstall unloads via launchctl bootout" "$calls" "launchctl bootout"
if [ -f "$plist" ]; then bad "uninstall → plist removed" "still present: $plist"; else ok "uninstall → plist removed"; fi
assert_absent   "uninstall issues no tart stop (VM stays up)" "$calls" "tart stop"
assert_contains "uninstall says the VM stays up"   "$(cat "$WORK/err")" "stays up"
assert_contains "uninstall names tart-rm for deletion" "$(cat "$WORK/err")" "tart-rm app-a"

# ── deleted-VM terminal path (foreground loop) ───────────────────────────────
# A SUCCEEDING `tart list` that omits the VM three times in a row makes the
# loop self-remove: log loudly, drop its plist, bootout its own label, exit 0
# — all on its own. The bounded kill-0 wait (house pattern from tart-up.sh)
# only guards against the hang that would mean the path regressed.
seedp="$LA/com.tart-stacks.supervise.app-a.plist"
mkdir -p "$LA"; printf 'seed\n' > "$seedp"
: > "$CALLS"
PATH="$MOCKBIN:$PATH" MOCK_ALIVE=0 \
  MOCK_TART_LIST_JSON='[{"Name":"other-vm","Source":"local","State":"running"}]' \
  TART_LAUNCHAGENTS_DIR="$LA" TART_LOG_DIR="$LOGS" \
  TART_SUPERVISE_POLL=0 TART_SUPERVISE_BACKOFF_BASE=0 TART_SUPERVISE_BACKOFF_CAP=0 \
  bash "$BIN/tart-supervise" app-a >/dev/null 2>"$WORK/term.err" &
sup=$!
for _ in $(seq 1 200); do kill -0 "$sup" 2>/dev/null || break; sleep 0.1; done
rc=124
if kill -0 "$sup" 2>/dev/null; then
  kill "$sup" 2>/dev/null; wait "$sup" 2>/dev/null || true
else
  rc=0; wait "$sup" || rc=$?
fi
if [ "$rc" -eq 0 ]; then ok "gone VM → loop exits 0 on its own"; else bad "gone VM → loop exits 0 on its own" "want rc=0 got rc=$rc (124 = hung; killed)"; fi
assert_contains "gone VM → loud terminal log" "$(cat "$WORK/term.err")" "gone from 'tart list'"
if [ -f "$seedp" ]; then bad "gone VM → plist self-removed" "still present: $seedp"; else ok "gone VM → plist self-removed"; fi
assert_contains "gone VM → bootout of own label" "$(cat "$CALLS")" "launchctl bootout gui/$(id -u)/com.tart-stacks.supervise.app-a"

# A confirmed sighting between misses resets the gone counter: with a limit of
# 2 and the answers absent, present, absent, absent, termination requires the
# two LAST misses — four list calls. Without the reset, call 3 would end it.
SEQ="$WORK/list.seq"
printf '%s\n' '[]' "$LIST_DEFAULT" '[]' '[]' > "$SEQ"
rm -f "${SEQ}.idx"
printf 'seed\n' > "$seedp"
: > "$CALLS"
PATH="$MOCKBIN:$PATH" MOCK_ALIVE=0 MOCK_TART_LIST_SEQ="$SEQ" \
  TART_LAUNCHAGENTS_DIR="$LA" TART_LOG_DIR="$LOGS" \
  TART_SUPERVISE_POLL=0 TART_SUPERVISE_BACKOFF_BASE=0 TART_SUPERVISE_BACKOFF_CAP=0 \
  TART_SUPERVISE_ABSENT_LIMIT=2 \
  bash "$BIN/tart-supervise" app-a >/dev/null 2>"$WORK/reset.err" &
sup=$!
for _ in $(seq 1 200); do kill -0 "$sup" 2>/dev/null || break; sleep 0.1; done
rc=124
if kill -0 "$sup" 2>/dev/null; then
  kill "$sup" 2>/dev/null; wait "$sup" 2>/dev/null || true
else
  rc=0; wait "$sup" || rc=$?
fi
if [ "$rc" -eq 0 ]; then ok "sighting between misses → loop still terminates cleanly"; else bad "sighting between misses → loop still terminates cleanly" "want rc=0 got rc=$rc (124 = hung; killed)"; fi
lcount=$(grep -c 'tart list' "$CALLS")
if [ "$lcount" -eq 4 ]; then ok "sighting reset the counter (termination took 4 list calls)"; else bad "sighting reset the counter (termination took 4 list calls)" "want 4 list calls, got $lcount"; fi

# A FAILING `tart list` must never trip the terminal path: the loop keeps
# retrying (the kill below is this test's expected end), the pre-seeded plist
# survives, and no bootout fires.
printf 'seed\n' > "$seedp"
: > "$CALLS"
PATH="$MOCKBIN:$PATH" MOCK_ALIVE=0 MOCK_TART_LIST_RC=1 \
  TART_LAUNCHAGENTS_DIR="$LA" TART_LOG_DIR="$LOGS" \
  TART_SUPERVISE_POLL=0 TART_SUPERVISE_BACKOFF_BASE=0 TART_SUPERVISE_BACKOFF_CAP=0 \
  bash "$BIN/tart-supervise" app-a >/dev/null 2>"$WORK/fail.err" &
sup=$!
sleep 2
if kill -0 "$sup" 2>/dev/null; then ok "list failure → still looping (no self-destruct)"; else bad "list failure → still looping (no self-destruct)" "exited early"; fi
kill "$sup" 2>/dev/null
wait "$sup" 2>/dev/null || true
if [ -f "$seedp" ]; then ok "list failure → plist survives"; else bad "list failure → plist survives" "plist was removed"; fi
assert_absent "list failure → no bootout" "$(cat "$CALLS")" "launchctl bootout"

printf '\n  %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
