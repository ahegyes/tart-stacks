#!/usr/bin/env bash
# Behavioral tests for shared/darwin/scripts/user-config.sh — the /mnt/shared
# parity link Tart's sealed system volume forces through synthetic.conf, the
# per-boot runtime-dir LaunchDaemon the forwarded agent sockets bind into, and
# the .zshenv PATH guard's idempotence. Runs the shipped script for real
# against a synthetic root via TART_ROOT (the seam the script exposes for
# exactly this reason) rather than reimplementing its logic. Plain bash, no
# framework — same technique as test/family-lib-darwin.sh: mocked binaries on
# PATH, subshell-scoped env, counted verdicts. chown and launchctl are the two
# commands here that would otherwise reach the real system (an ownership
# change, a launchd registration) and this suite runs on the owner's own Mac
# — both are mocked, never real.
set -uo pipefail

TEST_DIR=$(cd -P "$(dirname "$0")" >/dev/null 2>&1 && pwd); REPO=$(cd -P "$TEST_DIR/.." >/dev/null 2>&1 && pwd)
SCRIPT="$REPO/shared/darwin/scripts/user-config.sh"

pass=0 fail=0
ok()  { pass=$((pass + 1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  FAIL %s\n         %s\n' "$1" "${2:-}"; }
assert_eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "want » $2 « got » $3 «"; fi; }
assert_contains() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "want » $3 « in: $2" ;; esac; }

MOCKBIN=$(mktemp -d)

# Logging the FULL argv (not just the binary name) is what proves the script
# sent the expected owner/label through the mock — not merely that a
# same-named binary on PATH was reached without the run exploding.
cat > "$MOCKBIN/chown" <<'M'
#!/usr/bin/env bash
[ -n "${MOCK_LOG:-}" ] && printf 'chown %s\n' "$*" >> "$MOCK_LOG"
exit 0
M
cat > "$MOCKBIN/launchctl" <<'M'
#!/usr/bin/env bash
[ -n "${MOCK_LOG:-}" ] && printf 'launchctl %s\n' "$*" >> "$MOCK_LOG"
exit 0
M
chmod +x "$MOCKBIN/chown" "$MOCKBIN/launchctl"

WORK=$(mktemp -d)
trap 'rm -rf "$MOCKBIN" "$WORK"' EXIT
LOG="$WORK/cmdlog"

# setup_root <dir> — the tree a real macOS guest already has before this
# provisioner ever runs: the build user's home, /etc, and
# /Library/LaunchDaemons are base-image state, not something this script
# creates.
setup_root() { install -d -m 755 "$1/Users/admin" "$1/etc" "$1/Library/LaunchDaemons"; }

# invoke_script <root> <log> — run the SHIPPED script for real; rc via $?.
invoke_script() {
  PATH="$MOCKBIN:$PATH" TART_ROOT="$1" SUDO_USER=admin MOCK_LOG="$2" \
    bash "$SCRIPT" >"$1/stdout" 2>>"$1/stderr"
}

setup_root "$WORK"
rc=0
invoke_script "$WORK" "$LOG" || rc=$?
assert_eq "script exits 0 against a synthetic root" 0 "$rc"

# ── synthetic.conf ───────────────────────────────────────────────────────────
echo
echo "user-config (darwin) — synthetic.conf:"
SC="$WORK/etc/synthetic.conf"
# od -c renders a literal TAB as the two-character sequence \t; a
# space-separated line (the form macOS silently ignores) would not contain it.
tabs=$(od -c "$SC" | grep -c '\\t')
assert_eq "single TAB-separated line — a space is silently ignored by macOS" "1" "$tabs"
assert_contains "names mnt -> /opt/tart/mnt" "$(cat "$SC")" "$(printf 'mnt\t/opt/tart/mnt')"

# ── shared symlink ───────────────────────────────────────────────────────────
echo
echo "user-config (darwin) — shared symlink:"
assert_eq "resolves to Tart's share root" "/Volumes/My Shared Files" "$(readlink "$WORK/opt/tart/mnt/shared")"

# ── runtime-dir LaunchDaemon ─────────────────────────────────────────────────
echo
echo "user-config (darwin) — runtime-dir LaunchDaemon:"
PLIST="$WORK/Library/LaunchDaemons/tart-stacks-runtime-dir.plist"
assert_contains "owned by the build user, not root" "$(cat "$PLIST")" "<string>admin</string>"
assert_contains "labeled to match the launchctl enable call below" "$(cat "$PLIST")" "<string>tart-stacks-runtime-dir</string>"

# ── mocked privileged commands were actually reached ─────────────────────────
# The control the host-safety rule requires: proves the MOCK is the binary
# the script invoked, with the argv it actually sent — not merely that the
# run completed without exploding.
echo
echo "user-config (darwin) — privileged commands reach the mock with the right argv:"
LOGGED=$(cat "$LOG")
assert_contains "chown targets the build user, not root" "$LOGGED" "chown admin:staff"
assert_contains "launchctl enables the runtime-dir daemon by label" "$LOGGED" "launchctl enable system/tart-stacks-runtime-dir"

# ── .zshenv idempotence ───────────────────────────────────────────────────────
echo
echo "user-config (darwin) — .zshenv idempotence:"
ZSHENV="$WORK/Users/admin/.zshenv"
first=$(grep -c 'mise/shims' "$ZSHENV")
assert_eq "first run writes exactly one PATH block" "1" "$first"
rc2=0
invoke_script "$WORK" "$LOG" || rc2=$?
assert_eq "a re-run against the same root still exits 0" 0 "$rc2"
second=$(grep -c 'mise/shims' "$ZSHENV")
assert_eq "re-running does not duplicate the PATH block — the grep -q guard held" "1" "$second"

echo
echo "  $pass passed, $fail failed"
[ "$fail" -eq 0 ]
