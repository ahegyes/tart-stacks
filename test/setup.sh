#!/usr/bin/env bash
# Characterization tests for script/setup — the install and its --uninstall
# inverse. Everything is sandboxed: HOME and every TART_* seam point into a
# tmpdir and `tart` is a PATH mock, so no run can touch the real ~/.ssh,
# ~/.local/bin, LaunchAgents, or the live VMs on the machine running the
# suite. Covers the install surface (symlinks, completion, Include placement,
# scaffolds, the closing tart-ssh-sync run, the pubkey preflight warning,
# idempotent re-run), the tart-less install (warned, exit 0, nothing
# generated), the catch-all ordering warning, the uninstall inverse
# (supervised-VM gate, ownership-checked removal, byte-preserved user config,
# unmarked-Include refusal, kept config files), and argument handling. Plain
# bash, no framework. Run via script/test or directly.
set -uo pipefail

TEST_DIR=$(cd -P "$(dirname "$0")" >/dev/null 2>&1 && pwd)
REPO=$(cd -P "$TEST_DIR/.." >/dev/null 2>&1 && pwd)

pass=0 fail=0
ok()  { pass=$((pass + 1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  FAIL %s\n         %s\n' "$1" "$2"; }
assert_contains() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "want » $3 « in: $2" ;; esac; }
assert_absent()   { case "$2" in *"$3"*) bad "$1" "should NOT contain » $3 «" ;; *) ok "$1" ;; esac; }
assert_rc() { # label want — checks $rc from the last run_setup
  if [ "$rc" -eq "$2" ]; then ok "$1"; else bad "$1" "want rc=$2 got rc=$rc (stderr: $(cat "$ERR"))"; fi; }
assert_eq() { # label want got
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "want '$2' got '$3'"; fi; }
assert_path()    { if [ -e "$2" ]; then ok "$1"; else bad "$1" "missing: $2"; fi; }
assert_no_path() { if [ -e "$2" ] || [ -L "$2" ]; then bad "$1" "should not exist: $2"; else ok "$1"; fi; }
assert_link() { # label link expected-target
  if [ -L "$2" ] && [ "$(readlink "$2")" = "$3" ]; then ok "$1"
  else bad "$1" "want $2 -> $3, got $(readlink "$2" 2>/dev/null || echo '<no symlink>')"; fi; }
assert_same() { # label file reference — byte-for-byte equality
  if cmp -s "$2" "$3"; then ok "$1"; else bad "$1" "$2 no longer matches $3"; fi; }

WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
MOCKBIN="$WORK/mockbin"; mkdir -p "$MOCKBIN"
OUT="$WORK/out"; ERR="$WORK/err"

# `tart` mock: setup gates the closing sync on `command -v tart`, and
# tart-ssh-sync only resolves tart's path to bake into the generated
# ProxyCommand — neither executes it, so existing + executable is the job.
printf '#!/usr/bin/env bash\nexit 0\n' > "$MOCKBIN/tart"
chmod +x "$MOCKBIN/tart"

INC='Include ~/.ssh/config.d/tart-vms'
CMDS=(tart-up tart-ssh-sync tart-new tart-rm tart-supervise)

# sandbox <name> — point every env seam at a fresh $WORK/<name> tree, so no
# scenario can leak state into a later one's asserts.
sandbox() {
  SB="$WORK/$1"
  H="$SB/home"; LB="$SB/localbin"; COMP="$SB/comp"; CFG="$SB/cfg"; LA="$SB/la"
  SSHCFG="$H/.ssh/config"
  GEN="$H/.ssh/config.d/tart-vms"
  mkdir -p "$H/.ssh" "$LA"
}

run_setup() { # [args…] — rc in $rc; stdout in $OUT, stderr in $ERR.
  # RUN_PATH overrides PATH for one run (the tart-less case strips the mock
  # AND the host's real tart; /usr/bin:/bin still carries everything setup
  # itself needs). HOME is the sandbox — never the real one.
  rc=0
  PATH="${RUN_PATH:-$MOCKBIN:$PATH}" HOME="$H" \
    TART_LOCAL_BIN="$LB" TART_COMPDIR="$COMP" TART_SSH_CONFIG="$SSHCFG" \
    TART_FORWARDS="$CFG/forwards" TART_MOUNTS="$CFG/mounts" \
    TART_SSH_CONFIG_D="$GEN" TART_LAUNCHAGENTS_DIR="$LA" \
    bash "$REPO/script/setup" "$@" >"$OUT" 2>"$ERR" || rc=$?
}

# install: full first run against a pre-seeded ssh config, no pubkey yet
sandbox s1
printf 'Host github.com\n  User git\n' > "$SSHCFG"
cp "$SSHCFG" "$WORK/s1.orig"
run_setup
assert_rc "install → exit 0" 0
for c in "${CMDS[@]}"; do
  assert_link "install → $c linked into repo bin/" "$LB/$c" "$REPO/bin/$c"
done
assert_link "install → completion linked" "$COMP/_tart-new" "$REPO/completions/_tart-new"
assert_contains "install → Include block lands at the TOP" "$(head -n 1 "$SSHCFG")" "Added by tart-stacks"
assert_eq "install → exactly one Include line" "1" "$(grep -cxF "$INC" "$SSHCFG")"
assert_contains "install → user config intact below the block" "$(cat "$SSHCFG")" "Host github.com"
assert_path "install → forwards scaffolded" "$CFG/forwards"
assert_path "install → mounts scaffolded"   "$CFG/mounts"
assert_path "install → tart-vms generated (setup ran the first sync)" "$GEN"
# shellcheck disable=SC2012  # ls renders the mode portably (BSD stat and GNU stat disagree on flags); $GEN is a fixed sandbox path
assert_eq "install → tart-vms mode 600" "-rw-------" "$(ls -l "$GEN" | cut -c1-10)"
assert_contains "install → sync reported its write" "$(cat "$ERR")" "wrote $GEN"
assert_contains "install → pubkey preflight warns while ~/.ssh/tart-vm.pub is absent" "$(cat "$ERR")" "tart-vm.pub"

# install: idempotent re-run — pubkey now present, sentinel edits survive
touch "$H/.ssh/tart-vm.pub"
printf '# sentinel-edit\n' >> "$CFG/forwards"
run_setup
assert_rc "re-run → exit 0" 0
assert_eq "re-run → still exactly one Include line" "1" "$(grep -cxF "$INC" "$SSHCFG")"
assert_contains "re-run → forwards sentinel survives" "$(cat "$CFG/forwards")" "sentinel-edit"
assert_absent "re-run → pubkey warning gone once the key exists" "$(cat "$ERR")" "tart-vm.pub"

# uninstall: the inverse — user bytes preserved, generated state swept,
# per-VM config files kept
touch "${GEN}.rejected"   # stale failed candidate — swept with the output
run_setup --uninstall
assert_rc "uninstall → exit 0" 0
for c in "${CMDS[@]}"; do
  assert_no_path "uninstall → $c symlink removed" "$LB/$c"
done
assert_no_path "uninstall → completion removed" "$COMP/_tart-new"
assert_no_path "uninstall → generated tart-vms removed" "$GEN"
assert_no_path "uninstall → stale .rejected sibling removed" "${GEN}.rejected"
assert_same "uninstall → user ssh config byte-identical to pre-install" "$SSHCFG" "$WORK/s1.orig"
assert_path "uninstall → forwards kept" "$CFG/forwards"
assert_contains "uninstall → forwards edits kept" "$(cat "$CFG/forwards")" "sentinel-edit"
assert_path "uninstall → mounts kept" "$CFG/mounts"
assert_contains "uninstall → says the config files were kept" "$(cat "$OUT")" "kept the per-VM config files"
assert_contains "uninstall → closing summary printed" "$(cat "$OUT")" "uninstall done"

# install without tart: still exit 0, loud warning, nothing generated
sandbox s2
RUN_PATH="/usr/bin:/bin" run_setup
assert_rc "tart-less install → still exit 0" 0
assert_contains "tart-less install → LOUD not-generated warning" "$(cat "$ERR")" "NOT generated"
assert_contains "tart-less install → names the manual follow-up" "$(cat "$ERR")" "tart-ssh-sync"
assert_no_path "tart-less install → no tart-vms written" "$GEN"
assert_link "tart-less install → commands still linked" "$LB/tart-up" "$REPO/bin/tart-up"

# catch-all ordering warning (regression): Include below `Host *` is warned,
# never rewritten, never duplicated
sandbox s3
printf 'Host *\n  User nobody\n%s\n' "$INC" > "$SSHCFG"
run_setup
assert_rc "catch-all install → exit 0" 0
assert_contains "catch-all → ordering warning fires" "$(cat "$ERR")" "catch-all"
assert_eq "catch-all → no second Include added" "1" "$(grep -cxF "$INC" "$SSHCFG")"

# install: a foreign file squatting on a command name is warned and left —
# the installer must not destroy what it didn't create
sandbox s4a
mkdir -p "$LB"
printf 'not ours\n' > "$LB/tart-up"
run_setup
assert_rc "foreign file at install → setup still exits 0" 0
assert_eq "foreign file left untouched" "not ours" "$(cat "$LB/tart-up")"
assert_contains "foreign file at install → warned about" "$(cat "$ERR")" "not this repo's symlink"
assert_link "other commands still linked around it" "$LB/tart-new" "$REPO/bin/tart-new"

# uninstall: a foreign same-named symlink is warned and left
sandbox s4
run_setup
ln -sf /usr/bin/true "$LB/tart-up"   # same name, not our install
run_setup --uninstall
assert_rc "foreign symlink → uninstall exit 0" 0
assert_link "foreign symlink → left in place" "$LB/tart-up" "/usr/bin/true"
assert_contains "foreign symlink → warned about" "$(cat "$ERR")" "tart-up"
assert_no_path "foreign symlink → our other links still removed" "$LB/tart-new"

# uninstall: an Include without the marker comment is hand-written — warned,
# file untouched
sandbox s5
printf '%s\nHost github.com\n  User git\n' "$INC" > "$SSHCFG"
cp "$SSHCFG" "$WORK/s5.orig"
run_setup --uninstall
assert_rc "unmarked Include → uninstall exit 0" 0
assert_contains "unmarked Include → warned, not removed" "$(cat "$ERR")" "marker"
assert_same "unmarked Include → ssh config untouched" "$SSHCFG" "$WORK/s5.orig"

# uninstall: marker present but block shape drifted (blank separator edited
# away) → warned, file left byte-identical — the drift guard is what lets the
# install/uninstall block constants co-move safely
sandbox s5b
run_setup
grep -v '^$' "$SSHCFG" > "$SSHCFG.tmp" && mv "$SSHCFG.tmp" "$SSHCFG"
cp "$SSHCFG" "$WORK/s5b.orig"
run_setup --uninstall
assert_rc "drifted block → uninstall exit 0" 0
assert_contains "drifted block → warned about the drift" "$(cat "$ERR")" "drifted"
assert_same "drifted block → ssh config untouched" "$SSHCFG" "$WORK/s5b.orig"

# uninstall: supervised-VM gate refuses before removing anything
sandbox s6
run_setup
printf 'seed\n' > "$LA/com.tart-stacks.supervise.app-a.plist"
run_setup --uninstall
assert_rc "supervised gate → refuses with exit 1" 1
assert_contains "supervised gate → names the exact unsupervise command" "$(cat "$ERR")" "tart-supervise --uninstall app-a"
assert_contains "supervised gate → states nothing was removed" "$(cat "$ERR")" "nothing was removed"
assert_link "supervised gate → symlinks untouched" "$LB/tart-up" "$REPO/bin/tart-up"
assert_link "supervised gate → completion untouched" "$COMP/_tart-new" "$REPO/completions/_tart-new"
assert_path "supervised gate → generated config untouched" "$GEN"
assert_eq "supervised gate → Include block untouched" "1" "$(grep -cxF "$INC" "$SSHCFG")"

# argument handling
run_setup --help
assert_rc "--help → exit 0" 0
run_setup --frobnicate
assert_rc "bogus arg → exit 64" 64

printf '\n  %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
