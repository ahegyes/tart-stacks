#!/usr/bin/env bash
# Characterization tests for bin/tart-rm — no real VM, LaunchAgent, or
# known_hosts is touched: `tart` and `launchctl` are PATH mocks that record to
# $CALLS (`tart list` answers from a JSON fixture file; MOCK_TART_LIST_RC /
# MOCK_TART_STOP_RC make list/stop fail on demand), HOME is a sandbox so the
# real ssh-keygen scrubs a seeded known_hosts.tart, and the LaunchAgent dir is
# a tmpdir. The supervised case runs the REAL sibling tart-supervise against
# those mocks — the uninstall handoff is integration under test, not mocked.
# Covers arity, the lookup failure modes, base-image refusal, prefix
# normalization, stop→delete ordering, the stopped-VM path, supervised
# teardown, and the failed-stop abort. Plain bash, no framework. Run via
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
assert_eq()       { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "want » $2 « got » $3 «"; fi; }
check_rc() { local l="$1" want="$2"; shift 2; local got=0; "$@" >/dev/null 2>&1 || got=$?
  if [ "$got" -eq "$want" ]; then ok "$l"; else bad "$l" "want rc=$want got rc=$got"; fi; }
assert_rc() { # label want — checks $rc from the last run_rm
  if [ "$rc" -eq "$2" ]; then ok "$1"; else bad "$1" "want rc=$2 got rc=$rc"; fi; }
line_of() { grep -n -- "$1" "$CALLS" 2>/dev/null | head -n 1 | cut -d: -f1; }
assert_order() { # label earlier-pattern later-pattern — both in $CALLS, in that order
  local l="$1" a b
  a=$(line_of "$2"); b=$(line_of "$3")
  if [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ]; then ok "$l"
  else bad "$l" "want » $2 « (line ${a:-absent}) before » $3 « (line ${b:-absent}) in: $(tr '\n' '|' < "$CALLS")"; fi
}

WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
MOCKBIN="$WORK/bin"; mkdir -p "$MOCKBIN"
CALLS="$WORK/calls"; export CALLS
ERR="$WORK/stderr"
LA="$WORK/la"; mkdir -p "$LA"

# HOME sandbox: tart-rm scrubs $HOME/.ssh/known_hosts.tart with the real
# ssh-keygen, which must land here, never in the developer's real ~/.ssh.
mkdir -p "$WORK/home/.ssh"

# Fixture stacks/ + distros + desktops for the base-image gate (same shape as
# test/tart-new.sh): fedora is supported, php is a stack → fedora-php is base.
mkdir -p "$WORK/stacks/php"
printf 'fedora\n' > "$WORK/distros"
printf 'kde\n' > "$WORK/desktops"

# Mocks: every call lands in $CALLS. `tart list` answers from the JSON fixture
# file — or one line per call from $MOCK_TART_LIST_SEQ (last line repeats) for
# tests where the answer must CHANGE across lookups — or fails with
# $MOCK_TART_LIST_RC after a stderr marker (mirroring test/tart-up.sh); `stop`
# exits $MOCK_TART_STOP_RC; everything else records and succeeds. `launchctl`
# records and succeeds — the real tart-supervise's bootout goes through it.
# `ps` drives tart_vm_alive: MOCK_ALIVE=1 emits the canonical `tart run` line.
cat > "$MOCKBIN/tart" <<'M'
#!/usr/bin/env bash
echo "tart $*" >> "$CALLS"
case "${1:-}" in
  list)
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
    cat "$TART_LIST_JSON" ;;
  stop) exit "${MOCK_TART_STOP_RC:-0}" ;;
esac
exit 0
M
cat > "$MOCKBIN/launchctl" <<'M'
#!/usr/bin/env bash
echo "launchctl $*" >> "$CALLS"
exit 0
M
cat > "$MOCKBIN/ps" <<'M'
#!/usr/bin/env bash
# tart_vm_alive runs `ps -axo args=`; emit a `tart run` cmdline for it to scan.
if [ "${MOCK_ALIVE:-0}" = "1" ]; then
  printf '/opt/tart.app/Contents/MacOS/tart run %s --no-graphics\n' "${MOCK_VM:-app-a}"
fi
exit 0
M
chmod +x "$MOCKBIN/tart" "$MOCKBIN/launchctl" "$MOCKBIN/ps"

# Fixture list: one base image, two dev VMs, and an out-of-band VM occupying
# the reserved alias namespace.
export TART_LIST_JSON="$WORK/list.json"
cat > "$TART_LIST_JSON" <<'JSON'
[{"Name":"fedora-php","Source":"local","State":"stopped"},
 {"Name":"app-a","Source":"local","State":"running"},
 {"Name":"app-b","Source":"local","State":"stopped"},
 {"Name":"tart-ghost","Source":"local","State":"running"}]
JSON

run_rm() { # args... — exit code in $rc, stderr in $ERR, recorded calls in $CALLS
  : > "$CALLS"; rc=0
  PATH="$MOCKBIN:$PATH" HOME="$WORK/home" \
    MOCK_TART_LIST_RC="${MOCK_TART_LIST_RC-0}" MOCK_TART_STOP_RC="${MOCK_TART_STOP_RC-0}" \
    MOCK_TART_LIST_SEQ="${MOCK_TART_LIST_SEQ-}" \
    MOCK_ALIVE="${MOCK_ALIVE-1}" MOCK_VM=app-a \
    TART_LAUNCHAGENTS_DIR="$LA" \
    TART_STACKS_DIR="$WORK/stacks" TART_DISTROS="$WORK/distros" TART_DESKTOPS="$WORK/desktops" \
    bash "$BIN/tart-rm" "$@" >"$WORK/out" 2>"$ERR" || rc=$?
}

# Real-key pins for the scrub assertions (seeds must parse — ssh-keygen -R
# refuses to rewrite a file with invalid lines; the fixed -C keeps hostnames
# out of the key comment). The keeper token shares no substring with the
# scrubbed alias, so its survival check cannot false-pass.
ssh-keygen -q -t ed25519 -N '' -C seed -f "$WORK/seed-key"
seed_pub=$(<"$WORK/seed-key.pub")
KNOWN="$WORK/home/.ssh/known_hosts.tart"
seed_pins() { printf 'tart-app-a %s\ntart-rmkeep %s\n' "$seed_pub" "$seed_pub" > "$KNOWN"; }

# argument validation (HOME sandboxed even here — defense in depth should the
# preamble ever grow a HOME-touching step)
check_rc "no args → exit 64"  64 env PATH="$MOCKBIN:$PATH" HOME="$WORK/home" bash "$BIN/tart-rm"
check_rc "two args → exit 64" 64 env PATH="$MOCKBIN:$PATH" HOME="$WORK/home" bash "$BIN/tart-rm" a b
check_rc "--help → exit 0"    0  env PATH="$MOCKBIN:$PATH" HOME="$WORK/home" bash "$BIN/tart-rm" --help

# A bare miss is final even when an out-of-band VM occupies the corresponding
# reserved alias name: the diagnostic names only the form actually checked,
# and the unrelated VM is never stopped or deleted.
run_rm ghost
assert_rc       "unknown VM → exit 1" 1
assert_contains "unknown VM → error suggests tart list" "$(cat "$ERR")" "Try 'tart list'"
assert_absent   "bare miss → does not claim another form was tried" "$(cat "$ERR")" "also tried"
assert_eq       "bare miss → one as-given state probe" 1 "$(grep -c '^tart list --format json$' "$CALLS")"
assert_absent   "bare miss → does not stop literal tart-prefixed VM"   "$(cat "$CALLS")" "tart stop tart-ghost"
assert_absent   "bare miss → does not delete literal tart-prefixed VM" "$(cat "$CALLS")" "tart delete tart-ghost"

# The prefix is stripped before the only lookup, so the diagnostic names the
# stored form that was actually checked — there is no second form to report.
run_rm tart-nope
assert_rc       "unknown alias → exit 1" 1
assert_contains "unknown alias → error names the stored form" "$(cat "$ERR")" "VM 'nope' not found."
assert_absent   "unknown alias → claims no second form" "$(cat "$ERR")" "also tried"
assert_absent   "unknown alias → no tart stop"   "$(cat "$CALLS")" "tart stop"
assert_absent   "unknown alias → no tart delete" "$(cat "$CALLS")" "tart delete"

# a failing `tart list` is a broken tool, not a missing VM: named diagnostic
# with tart's own stderr surfaced, and no destructive call.
MOCK_TART_LIST_RC=1 run_rm app-a
assert_rc       "tart list failure → exit 1" 1
assert_contains "tart list failure → diagnostic names the tool" "$(cat "$ERR")" "'tart list' failed"
assert_contains "tart list failure → tart's stderr surfaced"    "$(cat "$ERR")" "MOCK_TART_LIST_STDERR_MARKER"
assert_absent   "tart list failure → no tart stop"   "$(cat "$CALLS")" "tart stop"
assert_absent   "tart list failure → no tart delete" "$(cat "$CALLS")" "tart delete"

# base image refusal: removing a clone-source stays a deliberate raw-tart act
run_rm fedora-php
assert_rc       "base image → exit 1" 1
assert_contains "base refusal says base image"           "$(cat "$ERR")" "base image"
assert_contains "base refusal names the deliberate path" "$(cat "$ERR")" "tart delete"
assert_absent   "base refusal → no delete issued by us"  "$(cat "$CALLS")" "tart delete"

# prefix form resolves to the bare stored name
run_rm tart-app-a
assert_rc       "prefix form → exit 0" 0
assert_contains "prefix form → delete uses the bare name"       "$(cat "$CALLS")" "tart delete app-a"
assert_absent   "prefix form → never deletes the prefixed name" "$(cat "$CALLS")" "delete tart-app-a"

# running unsupervised VM: stop precedes delete, no supervision machinery is
# touched, the alias pin is scrubbed and unrelated pins survive
seed_pins
run_rm app-a
assert_rc       "running VM → exit 0" 0
assert_order    "running VM → stop precedes delete" "tart stop app-a$" "tart delete app-a$"
assert_absent   "running VM (unsupervised) → no launchctl bootout" "$(cat "$CALLS")" "launchctl bootout"
assert_absent   "unsupervised final line does not claim supervision" "$(cat "$ERR")" "supervision"
assert_absent   "alias pin scrubbed"     "$(cat "$KNOWN")" "tart-app-a"
assert_contains "unrelated pin survives" "$(cat "$KNOWN")" "tart-rmkeep"

# stopped VM: no stop, straight to delete
run_rm app-b
assert_rc       "stopped VM → exit 0" 0
assert_absent   "stopped VM → no tart stop"    "$(cat "$CALLS")" "tart stop"
assert_contains "stopped VM → delete recorded" "$(cat "$CALLS")" "tart delete app-b"

# supervised running VM: the REAL sibling tart-supervise drops the
# LaunchAgent (bootout + plist removal) before stop and delete; the final
# line says so
plist="$LA/com.tart-stacks.supervise.app-a.plist"
printf 'seed\n' > "$plist"
seed_pins
run_rm app-a
assert_rc       "supervised VM → exit 0" 0
assert_contains "supervised VM → launchctl bootout recorded" "$(cat "$CALLS")" "launchctl bootout"
if [ -f "$plist" ]; then bad "supervised VM → plist removed by real tart-supervise" "still present: $plist"; else ok "supervised VM → plist removed by real tart-supervise"; fi
assert_order    "supervised VM → bootout precedes stop" "launchctl bootout" "tart stop app-a$"
assert_order    "supervised VM → stop precedes delete"  "tart stop app-a$"  "tart delete app-a$"
assert_contains "supervised VM → final line notes supervision" "$(cat "$ERR")" "supervision dropped"

# failing `tart stop` on a LIVE VM aborts the teardown: nothing is deleted,
# the pin survives
seed_pins
MOCK_TART_STOP_RC=7 run_rm app-a
assert_rc       "failing stop propagates its exit code" 7
assert_absent   "failing stop → no tart delete" "$(cat "$CALLS")" "tart delete"
assert_contains "failing stop → pin survives the aborted teardown" "$(cat "$KNOWN")" "tart-app-a"

# crash-wedged VM (listed running, no live process): the stop only clears
# tart's stored state, so even a failing one must not block the delete
seed_pins
MOCK_ALIVE=0 MOCK_TART_STOP_RC=7 run_rm app-a
assert_rc       "wedged VM → failing stop does not abort the teardown" 0
assert_contains "wedged VM → state-clearing stop attempted" "$(cat "$CALLS")" "tart stop app-a"
assert_contains "wedged VM → delete proceeds" "$(cat "$CALLS")" "tart delete app-a"
assert_absent   "wedged VM → alias pin scrubbed" "$(cat "$KNOWN")" "tart-app-a"

# the supervision drop races the supervisor's restart cycle: the state is
# re-resolved after the drop, so a VM captured "stopped" at lookup but running
# by then still gets stopped before the delete
SEQ="$WORK/rm-list.seq"
printf '%s\n' \
  '[{"Name":"app-a","Source":"local","State":"stopped"}]' \
  '[{"Name":"app-a","Source":"local","State":"running"}]' > "$SEQ"
rm -f "${SEQ}.idx"
printf 'seed\n' > "$plist"
MOCK_TART_LIST_SEQ="$SEQ" run_rm app-a
assert_rc       "post-drop re-resolve → exit 0" 0
assert_order    "post-drop re-resolve → stop still precedes delete" "tart stop app-a$" "tart delete app-a$"

printf '\n  %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
