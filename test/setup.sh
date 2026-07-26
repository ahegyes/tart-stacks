#!/usr/bin/env bash
# Characterization tests for script/setup — the install and its --uninstall
# inverse. Everything is sandboxed: HOME and every TART_* seam point into a
# tmpdir and `tart` is a PATH mock, so no run can touch the real ~/.ssh,
# ~/.local/bin or the live VMs on the machine running the
# suite. Covers the install surface (symlinks, completion, Include placement,
# scaffolds, the closing tart-ssh-sync run, the pubkey preflight warning,
# idempotent re-run), the tart-less install (warned, exit 0, nothing
# generated), the catch-all ordering warning, the uninstall inverse
# (ownership-checked removal, byte-preserved user config,
# unmarked-Include refusal, kept config files), and argument handling. Plain
# bash, no framework. Run via script/test or directly.
set -uo pipefail

TEST_DIR=$(cd -P "$(dirname "$0")" >/dev/null 2>&1 && pwd)
REPO=$(cd -P "$TEST_DIR/.." >/dev/null 2>&1 && pwd)

pass=0 fail=0
ok()  { pass=$((pass + 1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  FAIL %s\n         %s\n' "$1" "${2:-}"; }
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

# The closing tart-ssh-sync run refuses on ssh without `Match sessiontype`
# (OpenSSH < 10, e.g. the ubuntu CI runner), which would abort setup under
# set -e. Shim ssh to a parse-anything stub there so the install flow stays
# testable; full-fidelity validation runs wherever ssh is current.
if ! printf 'Match sessiontype shell\n' | ssh -G -F /dev/stdin __tart-probe >/dev/null 2>&1; then
  printf '#!/usr/bin/env bash\nexit 0\n' > "$MOCKBIN/ssh"
  chmod +x "$MOCKBIN/ssh"
  ok "old ssh detected: sync's ssh shimmed (full validation needs OpenSSH >= 10)"
fi

INC='Include ~/.ssh/config.d/tart-vms'
# Derived, not restated: every executable in bin/ must be installed and removed
# again. bin/lib/* is sourced, never executable, so -f -x selects exactly the
# commands — and a new command added to bin/ but forgotten in script/setup fails
# here instead of shipping uninstalled.
CMDS=()
for _c in "$REPO"/bin/*; do
  [ -f "$_c" ] && [ -x "$_c" ] && CMDS+=("${_c##*/}")
done
[ "${#CMDS[@]}" -gt 0 ] || { echo "no executables found in $REPO/bin" >&2; exit 1; }

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
printf 'app-a vnc\n' > "$CFG/gui"  # engine-rendered policy is user state, not generated SSH output
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
assert_contains "uninstall → gui config kept" "$(cat "$CFG/gui")" "app-a vnc"
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

# An Include below a SCOPED Host/Match block is worse than the catch-all case:
# ssh reads it only for the hosts that block matches, so it never applies to a
# tart-* alias at all. Verified against real ssh -G: nested → the Include's
# settings are absent; top-level → they apply.
for block in 'Host github.com' 'Match host github.com'; do
  sandbox "s3b-${block%% *}"
  printf '%s\n  User git\n%s\n' "$block" "$INC" > "$SSHCFG"
  cp "$SSHCFG" "$WORK/s3b.orig"
  run_setup
  assert_rc "Include under '$block' → exit 0" 0
  assert_contains "Include under '$block' → warned as nested" "$(cat "$ERR")" "inside the block that starts on line 1"
  assert_contains "Include under '$block' → names the move target" "$(cat "$ERR")" "above line 1"
  assert_eq "Include under '$block' → no second Include added" "1" "$(grep -cxF "$INC" "$SSHCFG")"
  assert_same "Include under '$block' → file left untouched" "$SSHCFG" "$WORK/s3b.orig"
done

# Only the ENCLOSING block decides the failure, and the two failures differ. With
# a catch-all directly above, `ssh -G` shows the Include IS read (a keyword it
# alone sets arrives) and only shared keywords lose — so the message must say
# that, and must name line 4, not the first block in the file.
sandbox s3d
printf 'Host github.com\n  User git\n\nHost *\n  User bob\n%s\n' "$INC" > "$SSHCFG"
run_setup
assert_contains "catch-all encloses → names the catch-all's own line" "$(cat "$ERR")" "inside the catch-all that starts on line 4"
assert_contains "catch-all encloses → says the keywords are outranked" "$(cat "$ERR")" "keeps the catch-all's value"
assert_contains "catch-all encloses → remedy targets the first block" "$(cat "$ERR")" "above line 1"

# The inverse arrangement is the one that reads alike and behaves differently: a
# catch-all FIRST but a scoped block enclosing the Include. `ssh -G` shows the
# Include is not read at all there, so naming the catch-all would give the wrong
# mechanism and send the reader looking for a keyword conflict that isn't there.
sandbox s3d2
printf 'Host *\n  User bob\nHost github.com\n  User git\n%s\n' "$INC" > "$SSHCFG"
run_setup
assert_contains "scoped block encloses despite an earlier catch-all → names the scoped block" "$(cat "$ERR")" "inside the block that starts on line 3"
assert_absent   "scoped block encloses despite an earlier catch-all → not called a catch-all" "$(cat "$ERR")" "catch-all that starts"
assert_contains "scoped block encloses despite an earlier catch-all → gives the scoping reason" "$(cat "$ERR")" "never applies to tart-* aliases"

# `Match all` matches every host, so ssh treats it as the catch-all case — and
# `final` may precede it. After any other criterion an `all` is that criterion's
# argument instead, which `ssh -G` confirms is not entered on the normal pass.
sandbox s3e
printf 'Match all\n  User bob\n%s\n' "$INC" > "$SSHCFG"
run_setup
assert_contains "Match all → recognised as a catch-all" "$(cat "$ERR")" "inside the catch-all that starts on line 1"
sandbox s3e2
printf 'Match final all\n  User bob\n%s\n' "$INC" > "$SSHCFG"
run_setup
assert_contains "Match final all → recognised as a catch-all" "$(cat "$ERR")" "inside the catch-all that starts on line 1"
for notall in 'Match canonical all' 'Match host all'; do
  sandbox "s3f-$(printf '%s' "$notall" | tr -cd '[:lower:]')"
  printf '%s\n  User bob\n%s\n' "$notall" "$INC" > "$SSHCFG"
  run_setup
  assert_contains "'$notall' → not a catch-all" "$(cat "$ERR")" "inside the block that starts on line 1"
done

# ssh_config separates a keyword from its argument by whitespace OR one `=`,
# accepts double-quoted arguments, and allows leading indentation — all four
# verified honoured by OpenSSH 10.2. An Include this scanner failed to see would
# get a second one added beside it, and two Includes fire the auto-start twice.
for spelling in 'Include=~/.ssh/config.d/tart-vms' 'Include = ~/.ssh/config.d/tart-vms' 'Include "~/.ssh/config.d/tart-vms"' '   Include ~/.ssh/config.d/tart-vms' 'include ~/.ssh/config.d/tart-vms'; do
  sandbox "s3g-$(printf '%s' "$spelling" | tr -cd 'a-z=" ' | tr ' =\"' '___')"
  printf '%s\nHost github.com\n  User git\n' "$spelling" > "$SSHCFG"
  run_setup
  assert_eq "an existing '$spelling' is recognised, not duplicated" "1" "$(grep -c 'config.d/tart-vms' "$SSHCFG")"
done

# `Host=*` is the same keyword/argument grammar on the block side.
sandbox s3h
printf 'Host=*\n  User bob\n%s\n' "$INC" > "$SSHCFG"
run_setup
assert_contains "Host=* → recognised as a catch-all block" "$(cat "$ERR")" "inside the catch-all that starts on line 1"

# A top-level Include with a scoped block BELOW it is correct — the placement
# rule is about the first Host/Match line, not about blocks existing at all.
sandbox s3c
printf '%s\nHost github.com\n  User git\n' "$INC" > "$SSHCFG"
run_setup
assert_contains "Include above a scoped block → reported correctly placed" "$(cat "$OUT")" "correctly placed"
assert_absent   "Include above a scoped block → no warning" "$(cat "$ERR")" "Move '"

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

# The completion name gets the same protection: the uninstall already refuses to
# remove a foreign file there, so clobbering one at install would delete the
# user's own completion and leave ours for `make uninstall` to take away.
sandbox s4b
mkdir -p "$COMP"
printf '#compdef tart-new\n# hand-written\n' > "$COMP/_tart-new"
run_setup
assert_rc "foreign completion at install → setup still exits 0" 0
assert_contains "foreign completion left untouched" "$(cat "$COMP/_tart-new")" "hand-written"
assert_contains "foreign completion → warned about" "$(cat "$ERR")" "_tart-new"
assert_link "foreign completion → commands still linked" "$LB/tart-up" "$REPO/bin/tart-up"

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

# A dotfiles-managed ~/.ssh/config is a symlink into that repo. mktemp+mv is
# what makes the rewrite atomic, but it renames over the LINK — the dotfiles
# source would freeze at its pre-install content while ssh read a detached copy.
sandbox s6
DOTFILES="$SB/dotfiles"; mkdir -p "$DOTFILES"
printf 'Host github.com\n  User git\n' > "$DOTFILES/ssh_config"
ln -s "$DOTFILES/ssh_config" "$SSHCFG"
run_setup
assert_rc "symlinked ssh config → exit 0" 0
if [ -L "$SSHCFG" ]; then ok "symlinked ssh config → link survives the write"
else bad "symlinked ssh config → link survives the write" "$SSHCFG is no longer a symlink"; fi
assert_contains "symlinked ssh config → Include reaches the dotfiles source" "$(cat "$DOTFILES/ssh_config")" "$INC"
assert_contains "symlinked ssh config → user config preserved in the source" "$(cat "$DOTFILES/ssh_config")" "Host github.com"
run_setup
assert_eq "symlinked ssh config → re-run adds no second Include" "1" "$(grep -cxF "$INC" "$DOTFILES/ssh_config")"
run_setup --uninstall
assert_rc "symlinked ssh config → uninstall exit 0" 0
assert_absent "symlinked ssh config → uninstall strips the Include from the source" "$(cat "$DOTFILES/ssh_config")" "config.d/tart-vms"
if [ -L "$SSHCFG" ]; then ok "symlinked ssh config → link survives the uninstall"
else bad "symlinked ssh config → link survives the uninstall" "$SSHCFG is no longer a symlink"; fi

# TART_SSH_CONFIG_D is documented as an override, so the Include has to name the
# file the sync actually writes — a hard-coded path pointed ssh at nothing.
sandbox s7
ALT_GEN="$H/.ssh/alt.d/tart-vms"
GEN="$ALT_GEN"
run_setup
assert_rc "overridden generated path → exit 0" 0
assert_contains "overridden generated path → Include names it" "$(cat "$SSHCFG")" "Include ~/.ssh/alt.d/tart-vms"
assert_absent   "overridden generated path → no default-path Include" "$(cat "$SSHCFG")" "config.d/tart-vms"
assert_path     "overridden generated path → sync wrote there" "$ALT_GEN"
run_setup
assert_eq "overridden generated path → re-run recognizes its own Include" "1" \
  "$(grep -cF 'Include ~/.ssh/alt.d/tart-vms' "$SSHCFG")"
assert_contains "overridden generated path → re-run reports it placed" "$(cat "$OUT")" "correctly placed"
# The uninstall has to recognise the same overridden path, or it leaves the
# Include behind pointing at a file it just deleted.
run_setup --uninstall
assert_rc     "overridden generated path → uninstall exit 0" 0
assert_absent "overridden generated path → uninstall strips its Include" "$(cat "$SSHCFG")" "alt.d/tart-vms"
assert_no_path "overridden generated path → uninstall removes the generated file" "$ALT_GEN"

# A generated path OUTSIDE $HOME takes the absolute-spelling branch, which no
# ~/-relative case exercises.
sandbox s7b
OUT_GEN="$SB/outside/tart-vms"
GEN="$OUT_GEN"
run_setup
assert_rc       "generated path outside \$HOME → exit 0" 0
assert_contains "generated path outside \$HOME → Include names it absolutely" "$(cat "$SSHCFG")" "Include $OUT_GEN"
assert_path     "generated path outside \$HOME → sync wrote there" "$OUT_GEN"
run_setup
assert_eq "generated path outside \$HOME → re-run adds no second Include" "1" "$(grep -cF "Include $OUT_GEN" "$SSHCFG")"
run_setup --uninstall
assert_absent "generated path outside \$HOME → uninstall strips its Include" "$(cat "$SSHCFG")" "$OUT_GEN"

# ssh_config(5) resolves a bare relative Include against ~/.ssh, so this is a
# third legal spelling of the same file. Unrecognised, setup adds a second
# Include — and two Includes of the generated config fire the auto-start twice.
sandbox s7c
printf 'Include config.d/tart-vms\nHost github.com\n  User git\n' > "$SSHCFG"
run_setup
assert_rc     "relative-form Include → exit 0" 0
assert_eq     "relative-form Include → no second Include added" "1" "$(grep -c 'config.d/tart-vms' "$SSHCFG")"
assert_contains "relative-form Include → reported as placed" "$(cat "$OUT")" "correctly placed"

# ...while a neighbour that merely shares a path prefix is not ours.
sandbox s7d
printf 'Include ~/.ssh/config.d/tart-vms-extra\nHost *\n  User bob\n' > "$SSHCFG"
run_setup
assert_contains "prefix-sharing neighbour → our own Include still added" "$(cat "$SSHCFG")" "$INC"
assert_contains "prefix-sharing neighbour → left in place" "$(cat "$SSHCFG")" "tart-vms-extra"

# A generated path containing whitespace has to be written quoted, or ssh splits
# it and the scanner cannot field-match it — which added one Include per run.
sandbox s7e
mkdir -p "$SB/out dir"
GEN="$SB/out dir/tart-vms"
run_setup
assert_rc       "spaced generated path → exit 0" 0
assert_contains "spaced generated path → Include is quoted" "$(cat "$SSHCFG")" "Include \"$SB/out dir/tart-vms\""
run_setup
run_setup
assert_eq "spaced generated path → still one Include after three runs" "1" "$(grep -c 'out dir/tart-vms' "$SSHCFG")"
if ssh -G -F "$SSHCFG" someprobe >/dev/null 2>&1; then ok "spaced generated path → ssh still parses the config"
else bad "spaced generated path → ssh still parses the config" "ssh -G rejected it"; fi

# setup is run through a symlink by anything that puts script/ on a path; the
# repo it links the commands from must still be this checkout.
sandbox s8
ln -s "$REPO/script/setup" "$SB/setup-link"
rc=0
PATH="$MOCKBIN:$PATH" HOME="$H" \
  TART_LOCAL_BIN="$LB" TART_COMPDIR="$COMP" TART_SSH_CONFIG="$SSHCFG" \
  TART_FORWARDS="$CFG/forwards" TART_MOUNTS="$CFG/mounts" \
  TART_SSH_CONFIG_D="$GEN" \
  bash "$SB/setup-link" >"$OUT" 2>"$ERR" || rc=$?
assert_rc   "invoked through a symlink → exit 0" 0
assert_link "invoked through a symlink → links into this checkout" "$LB/tart-up" "$REPO/bin/tart-up"

# argument handling
run_setup --help
assert_rc "--help → exit 0" 0
run_setup --frobnicate
assert_rc "bogus arg → exit 64" 64

printf '\n  %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
