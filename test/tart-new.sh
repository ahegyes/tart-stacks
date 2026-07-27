#!/usr/bin/env bash
# Characterization tests for bin/tart-new. Plain bash, no framework (matches
# test/parsing.sh). Mocks `tart` on PATH and points TART_STACKS_DIR at a
# fixture stacks/ tree so stack validation, image-built detection, collision
# guarding, and resource pass-through are all exercised without a real VM.
set -uo pipefail

TEST_DIR=$(cd -P "$(dirname "$0")" >/dev/null 2>&1 && pwd)
REPO=$(cd -P "$TEST_DIR/.." >/dev/null 2>&1 && pwd)
BIN="$REPO/bin"

pass=0 fail=0
ok()  { pass=$((pass + 1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  FAIL %s\n         %s\n' "$1" "${2:-}"; }
assert_eq()       { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "want » $2 « got » $3 «"; fi; }
assert_contains() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "want » contains » $3 « got » $2 «" ;; esac; }
assert_path()     { if [ -e "$2" ]; then ok "$1"; else bad "$1" "missing: $2"; fi; }
assert_no_path()  { if [ -e "$2" ]; then bad "$1" "should not exist: $2"; else ok "$1"; fi; }
assert_absent()   { case "$2" in *"$3"*) bad "$1" "want » absent » $3 « got » $2 «" ;; *) ok "$1" ;; esac; }
check() { # label expected-rc cmd...
  local label="$1" want="$2"; shift 2
  local got=0; "$@" || got=$?
  if [ "$got" -eq "$want" ]; then ok "$label"; else bad "$label" "want » rc $want « got » rc $got «"; fi
}

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
# HOME sandbox for run_new: tart-new scrubs $HOME/.ssh/known_hosts.tart after a
# clone, which must land here, never in the developer's real ~/.ssh.
mkdir -p "$WORK/home/.ssh"

# Fixture stacks/ tree: two stacks present (dirs no longer carry OS prefix).
mkdir -p "$WORK/stacks/php/scripts" "$WORK/stacks/jvm/scripts"

# Supported-OS fixture used by the pure-helper and main-flow sections.
printf 'fedora\n' > "$WORK/os"
# A two-OS variant for tart_is_base_image tests that need ubuntu too.
printf 'fedora\nubuntu\n' > "$WORK/os2"
# Desktop tokens for the GUI-flavor arm of tart_is_base_image.
printf 'kde\nxfce\n' > "$WORK/desktops"

# Mock `tart` so list output is deterministic and clone/set are recorded.
# Mirrors parsing.sh's fake-tart-on-PATH approach. .Source=="local" is the
# real field tart-new's image_built keys on. MOCK_TART_SET_RC makes `tart set`
# fail with that status (the call is still recorded first).
mkdir -p "$WORK/bin"
cat > "$WORK/bin/tart" <<'TART'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$TART_CALLS"
case "$1" in
  list) cat "$TART_LIST_JSON" ;;
  set)  exit "${MOCK_TART_SET_RC:-0}" ;;
  *)    : ;;
esac
exit 0
TART
chmod +x "$WORK/bin/tart"
export TART_CALLS="$WORK/calls"
export TART_LIST_JSON="$WORK/list.json"
: > "$TART_CALLS"

# A list where fedora-php is built (local) but fedora-jvm is not, plus an
# existing project VM "app-a" and an OCI image that must not count as built.
cat > "$TART_LIST_JSON" <<'JSON'
[{"Name":"fedora-php","Source":"local"},
 {"Name":"app-a","Source":"local"},
 {"Name":"fedora-jvm","Source":"oci"}]
JSON

# End-to-end: run the whole script with mocked tart + fixture stacks. Assert on
# exit code, stderr message, and the recorded tart calls.
run_new() { # args... -> stdout; stderr to $WORK/err; exit code in $rc
  rc=0
  PATH="$WORK/bin:$PATH" TART_STACKS_DIR="$WORK/stacks" TART_OS_FILE="$WORK/os" TART_OS_FILES="$WORK/os" TART_DESKTOPS="$WORK/desktops" HOME="$WORK/home" \
    bash "$BIN/tart-new" "$@" >"$WORK/out" 2>"$WORK/err" </dev/null || rc=$?
}

echo "bin/tart-new — main flow:"

# Unknown stack → exit 1, lists available.
run_new app-x rust fedora
assert_eq       "unknown stack exits 1" 1 "$rc"
assert_contains "unknown stack lists available" "$(<"$WORK/err")" "available: jvm, php"

# Unsupported OS → exit 1, mentions "not supported".
run_new app-x php arch
assert_eq       "unsupported OS exits 1" 1 "$rc"
assert_contains "unsupported OS mentions not supported" "$(<"$WORK/err")" "not supported"

# Unsupported desktop → exit 1, lists the supported tokens.
run_new app-x php fedora cinnamon
assert_eq       "unsupported desktop exits 1" 1 "$rc"
assert_contains "unsupported desktop mentions not supported" "$(<"$WORK/err")" "desktop 'cinnamon' not supported"

# Unbuilt GUI flavor → the hint carries the GUI build args.
run_new app-x php fedora kde
assert_eq       "unbuilt GUI image exits 1 non-interactively" 1 "$rc"
assert_contains "unbuilt GUI error names the flavor image" "$(<"$WORK/err")" "image 'fedora-php-kde' is not built"
assert_contains "unbuilt GUI hint carries GUI=1 DE=" "$(<"$WORK/err")" "make build STACK=php OS=fedora GUI=1 DE=kde"

# Unbuilt stack, non-interactive → exit 1, prints the build command, no clone.
: > "$TART_CALLS"
run_new app-x jvm fedora
assert_eq       "unbuilt image exits 1 non-interactively" 1 "$rc"
assert_contains "unbuilt error names the image"      "$(<"$WORK/err")" "image 'fedora-jvm' is not built"
assert_contains "unbuilt image prints build command" "$(<"$WORK/err")" "make build STACK=jvm OS=fedora"
assert_absent   "unbuilt image does not clone" "$(<"$TART_CALLS")" "clone"

# Name collision → exit 1, no clone.
: > "$TART_CALLS"
run_new app-a php fedora
assert_eq       "collision exits 1" 1 "$rc"
assert_contains "collision message names the VM" "$(<"$WORK/err")" "'app-a' already exists"
assert_absent   "collision does not clone" "$(<"$TART_CALLS")" "clone"

# Collision with an unbuilt image → the collision gate wins: no build hint, no
# build offer for a name that can't be used anyway.
: > "$TART_CALLS"
run_new app-a jvm fedora
assert_eq       "collision precedes the build gate" 1 "$rc"
assert_contains "collision-vs-unbuilt reports the collision" "$(<"$WORK/err")" "'app-a' already exists"
assert_absent   "collision-vs-unbuilt skips the build hint"  "$(<"$WORK/err")" "build it with:"
assert_absent   "collision-vs-unbuilt does not clone" "$(<"$TART_CALLS")" "clone"

# Seed known_hosts.tart with real-key pins: a recreated VM gets a fresh host
# key, so tart-new drops the alias's stale pin while unrelated pins survive.
# (Seeds must parse — ssh-keygen -R refuses to rewrite a file with invalid
# lines — and the fixed -C keeps hostnames out of the key comment.)
ssh-keygen -q -t ed25519 -N '' -C seed -f "$WORK/seed-key"
seed_pub=$(<"$WORK/seed-key.pub")
printf 'tart-web %s\ntart-keep %s\n' "$seed_pub" "$seed_pub" > "$WORK/home/.ssh/known_hosts.tart"

# Happy path with resources → clones from fedora-php, then tart set.
: > "$TART_CALLS"
run_new web php fedora --cpu 4 --memory 8192 --disk-size 60
assert_eq       "happy path exits 0" 0 "$rc"
assert_contains "clones from the stack image" "$(<"$TART_CALLS")" "clone fedora-php web"
assert_contains "sets resources"              "$(<"$TART_CALLS")" "set web --cpu 4 --memory 8192 --disk-size 60"
assert_contains "prints next-step hint"       "$(<"$WORK/err")"   "next: ssh tart-web"
assert_absent   "scrubs the alias's stale known_hosts pin" "$(<"$WORK/home/.ssh/known_hosts.tart")" "tart-web"
assert_contains "unrelated known_hosts pins survive"       "$(<"$WORK/home/.ssh/known_hosts.tart")" "tart-keep"

# --opt=value parses identically to --opt value (same recorded tart set).
: > "$TART_CALLS"
run_new eq php fedora --cpu=4 --memory=8192 --disk-size=60
assert_eq       "equals-form exits 0" 0 "$rc"
assert_contains "equals-form folds into the same tart set" "$(<"$TART_CALLS")" "set eq --cpu 4 --memory 8192 --disk-size 60"

# Happy path without resource flags → clones, no `set`.
: > "$TART_CALLS"
run_new bare php fedora
assert_eq     "no-resource path exits 0" 0 "$rc"
assert_absent "no-resource path skips tart set" "$(<"$TART_CALLS")" "set bare"
assert_absent "headless clone is given no display" "$(<"$TART_CALLS")" "--display"

# A GUI clone is sized at create time. Tart's 1024x768 default cannot be raised
# from inside the guest — the resolution belongs to the virtual display, not the
# X session — so a desktop flavor that inherited it would stay unusable for life.
cat > "$TART_LIST_JSON" <<'JSON'
[{"Name":"fedora-php","Source":"local"},
 {"Name":"fedora-php-kde","Source":"local"}]
JSON
: > "$TART_CALLS"
run_new deskvm php fedora kde
assert_eq       "GUI clone exits 0" 0 "$rc"
assert_contains "GUI clone sizes its display" "$(<"$TART_CALLS")" "set deskvm --display 1920x1080 --display-refit"

: > "$TART_CALLS"
run_new deskvm2 php fedora kde --display 2560x1440
assert_contains "explicit --display overrides the GUI default" "$(<"$TART_CALLS")" "set deskvm2 --display 2560x1440 --display-refit"

# Restore the shared fixture list for the cases below.
cat > "$TART_LIST_JSON" <<'JSON'
[{"Name":"fedora-php","Source":"local"},
 {"Name":"app-a","Source":"local"},
 {"Name":"fedora-jvm","Source":"oci"}]
JSON

# --display parses in both forms and is validated before anything is cloned:
# `tart set` runs after `tart clone`, so a bad geometry would strand a VM.
cat > "$TART_LIST_JSON" <<'JSON'
[{"Name":"fedora-php","Source":"local"},
 {"Name":"fedora-php-kde","Source":"local"}]
JSON
: > "$TART_CALLS"
run_new deskvm4 php fedora kde --display=2560x1440
assert_contains "equals-form display folds into the same tart set" "$(<"$TART_CALLS")" \
  "set deskvm4 --display 2560x1440 --display-refit"

: > "$TART_CALLS"
run_new deskvm5 php fedora kde --display 1920X1080
assert_eq     "capital-X geometry → exit 64" 64 "$rc"
assert_absent "invalid geometry clones nothing" "$(<"$TART_CALLS")" "clone"

: > "$TART_CALLS"
run_new deskvm6 php fedora kde --display
assert_eq "--display with no value → exit 64" 64 "$rc"

# An empty value is not the same as an absent flag: the GUI default substitutes
# for it, so both spellings must be refused rather than clone at 1920x1080.
# `--display="$GEOM"` with GEOM unset is the way a caller reaches this.
: > "$TART_CALLS"
run_new deskvm7 php fedora kde --display=
assert_eq       "--display= (empty, equals form) → exit 64" 64 "$rc"
assert_contains "empty display names the flag" "$(<"$WORK/err")" "option '--display' requires a value"
assert_absent   "empty display clones nothing" "$(<"$TART_CALLS")" "clone"

: > "$TART_CALLS"
run_new deskvm8 php fedora kde --display ''
assert_eq       "--display '' (empty, space form) → exit 64" 64 "$rc"
assert_absent   "empty space-form display clones nothing" "$(<"$TART_CALLS")" "clone"

# Restore the shared fixture list for the cases below.
cat > "$TART_LIST_JSON" <<'JSON'
[{"Name":"fedora-php","Source":"local"},
 {"Name":"app-a","Source":"local"},
 {"Name":"fedora-jvm","Source":"oci"}]
JSON

# `tart set` failure after a successful clone: the scrub precedes the clone, so
# the aborted create leaves no stale alias pin behind; unrelated pins survive.
printf 'tart-half %s\ntart-keep2 %s\n' "$seed_pub" "$seed_pub" > "$WORK/home/.ssh/known_hosts.tart"
: > "$TART_CALLS"
MOCK_TART_SET_RC=7 run_new half php fedora --cpu 2
assert_eq       "failing tart set propagates its exit code" 7 "$rc"
assert_contains "clone ran before the failing set" "$(<"$TART_CALLS")" "clone fedora-php half"
assert_contains "set was attempted"                "$(<"$TART_CALLS")" "set half --cpu 2"
assert_absent   "alias pin scrubbed despite the failed set" "$(<"$WORK/home/.ssh/known_hosts.tart")" "tart-half"
assert_contains "unrelated pin survives the aborted create" "$(<"$WORK/home/.ssh/known_hosts.tart")" "tart-keep2"
# The half-configured clone is ours (the collision gate proved the name free),
# and leaving it behind makes the next attempt die at that gate instead.
assert_contains "failing set deletes the clone it left behind" "$(<"$TART_CALLS")" "delete half"
assert_contains "failing set says it deleted the clone" "$(<"$WORK/err")" "deleting the clone"

# Bad arity (only 2 positionals, missing OS) → usage, exit 64.
run_new only-one two
assert_eq "missing OS arg exits 64" 64 "$rc"

# Invalid names refused at create time — the name becomes the ssh alias, the
# guest hostname (hostname -s must equal it), and a vm-pattern token.
: > "$TART_CALLS"
run_new app.v2 php fedora
assert_eq       "dotted name refused at create" 1 "$rc"
assert_contains "name refusal explains itself" "$(<"$WORK/err")" "invalid VM name"
assert_absent   "dotted name → no clone" "$(<"$TART_CALLS")" "clone"
run_new a,b php fedora
assert_eq "comma name refused at create" 1 "$rc"
run_new _lead php fedora
assert_eq "leading-underscore name refused at create" 1 "$rc"
run_new tart-foo php fedora
assert_eq       "tart- prefixed name refused at create" 1 "$rc"
assert_contains "refusal names the reserved prefix" "$(<"$WORK/err")" "reserved"

# Space-form flag with no value → usage error (64), not a raw set -u death.
run_new foo php fedora --cpu
assert_eq       "valueless --cpu exits 64" 64 "$rc"
assert_contains "valueless --cpu names the flag" "$(<"$WORK/err")" "option '--cpu' requires a value"
assert_contains "valueless --cpu prints usage"   "$(<"$WORK/err")" "usage: tart-new"
assert_absent   "valueless --cpu is a clean usage error" "$(<"$WORK/err")" "unbound variable"
run_new foo php fedora --memory
assert_eq "valueless --memory exits 64" 64 "$rc"
run_new foo php fedora --disk-size
assert_eq "valueless --disk-size exits 64" 64 "$rc"

# An EMPTY value is the same defect one step later: every consumer reads "" as
# "flag absent", so the resource is silently not set while the exit status
# claims it was. `--cpu="$N"` with N unset is how a caller reaches this.
for empty_flag in --cpu --memory --disk-size; do
  : > "$TART_CALLS"
  run_new emptyflag php fedora "$empty_flag="
  assert_eq       "$empty_flag= (empty, equals form) → exit 64" 64 "$rc"
  assert_contains "$empty_flag= names the flag" "$(<"$WORK/err")" "option '$empty_flag' requires a value"
  assert_absent   "$empty_flag= clones nothing" "$(<"$TART_CALLS")" "clone"
  : > "$TART_CALLS"
  run_new emptyflag php fedora "$empty_flag" ''
  assert_eq       "$empty_flag '' (empty, space form) → exit 64" 64 "$rc"
  assert_absent   "$empty_flag '' clones nothing" "$(<"$TART_CALLS")" "clone"
done

# Base-image names are the reserved clone-source namespace: tart-up, tart-down
# and tart-rm all refuse them, so creating one mints a VM nothing downstream
# will touch. The refusal also has to precede the collision gate, whose
# "or 'tart-rm $NAME' first" remedy tart-rm would decline for such a name.
for reserved in fedora-php fedora-base fedora-php-kde; do
  : > "$TART_CALLS"
  run_new "$reserved" php fedora
  assert_eq       "reserved base-image name '$reserved' → exit 1" 1 "$rc"
  assert_contains "reserved '$reserved' → refusal explains itself" "$(<"$WORK/err")" "reserved base-image name"
  assert_absent   "reserved '$reserved' → no clone" "$(<"$TART_CALLS")" "clone"
  assert_absent   "reserved '$reserved' → not reported as a collision" "$(<"$WORK/err")" "already exists"
done

# A hyphenated project name that merely looks like one stays allowed — the
# classification is anchored on the supported OS and desktop sets.
: > "$TART_CALLS"
run_new web-php php fedora
assert_eq     "look-alike project name still allowed" 0 "$rc"
assert_contains "look-alike project name clones" "$(<"$TART_CALLS")" "clone fedora-php web-php"

# ── tart_is_base_image unit tests ────────────────────────────────────────────
# Source bin/lib/common.sh and exercise it directly.
# shellcheck source=bin/lib/common.sh
. "$BIN/lib/common.sh"

echo "bin/lib/common.sh — tart_valid_vm_name:"
check "plain name valid"             0 tart_valid_vm_name app-a
check "digits and underscore valid"  0 tart_valid_vm_name a1_b2
check "dotted name invalid"          1 tart_valid_vm_name app.v2
check "comma name invalid"           1 tart_valid_vm_name a,b
check "star invalid"                 1 tart_valid_vm_name '*'
check "leading dash invalid"         1 tart_valid_vm_name -x
check "leading underscore invalid"   1 tart_valid_vm_name _x
check "empty invalid"                1 tart_valid_vm_name ''
check "reserved tart- prefix invalid" 1 tart_valid_vm_name tart-x
# The glob classes are byte ranges only under LC_ALL=C. The locale is forced on
# the call, not inherited: both CI runners default to C, where an unpinned
# validator passes this case too and the assertion would prove nothing.
# shellcheck disable=SC2016  # $1 is the child shell's argument, not this one's
utf8_name_check() { # <label> <expected-rc> <name>
  check "$1" "$2" env LC_ALL=en_US.UTF-8 bash -c '. "$1"; shift; tart_valid_vm_name "$1"' _ "$BIN/lib/common.sh" "$3"
}
utf8_name_check "accented name invalid under a UTF-8 locale"  1 café
utf8_name_check "plain name still valid under a UTF-8 locale" 0 app-a

echo "bin/lib/common.sh — tart_is_base_image:"
check "<os>-base is a base"            0 tart_is_base_image fedora-base "$WORK/stacks" "$WORK/os2" "$WORK/desktops"
check "ubuntu-base is a base"          0 tart_is_base_image ubuntu-base "$WORK/stacks" "$WORK/os2" "$WORK/desktops"
check "<os>-<stack> is a base"         0 tart_is_base_image fedora-php  "$WORK/stacks" "$WORK/os2" "$WORK/desktops"
check "ubuntu-jvm is a base"           0 tart_is_base_image ubuntu-jvm  "$WORK/stacks" "$WORK/os2" "$WORK/desktops"
check "GUI flavor is a base"           0 tart_is_base_image fedora-php-kde "$WORK/stacks" "$WORK/os2" "$WORK/desktops"
check "GUI flavor, 2nd de token"       0 tart_is_base_image ubuntu-jvm-xfce "$WORK/stacks" "$WORK/os2" "$WORK/desktops"
check "unknown de suffix not a base"   1 tart_is_base_image fedora-php-2 "$WORK/stacks" "$WORK/os2" "$WORK/desktops"
check "de without a stack not a base"  1 tart_is_base_image fedora-kde  "$WORK/stacks" "$WORK/os2" "$WORK/desktops"
check "plain dev VM not a base"        1 tart_is_base_image app-a       "$WORK/stacks" "$WORK/os2" "$WORK/desktops"
check "hyphenated dev VM not a base"   1 tart_is_base_image web-php     "$WORK/stacks" "$WORK/os2" "$WORK/desktops"
check "unsupported-prefix not a base"    1 tart_is_base_image arch-php    "$WORK/stacks" "$WORK/os2" "$WORK/desktops"
check "-base without an OS not a base" 1 tart_is_base_image app-base    "$WORK/stacks" "$WORK/os2" "$WORK/desktops"

# Unreadable classification data refuses loudly instead of failing open — the
# helper gates tart-rm's delete path. (Subshell: the guard exits the shell.)
( tart_is_base_image app-a "$WORK/stacks" "$WORK/absent-os" "$WORK/desktops" ) 2>"$WORK/base-err"; brc=$?
if [ "$brc" -ne 0 ]; then ok "missing OS file → loud refusal, no fail-open"; else bad "missing OS file → loud refusal, no fail-open" "want rc!=0 got rc=0"; fi
assert_contains "refusal names the unreadable file" "$(<"$WORK/base-err")" "absent-os"
( tart_is_base_image app-a "$WORK/stacks" "$WORK/os2" "$WORK/absent-desktops" ) 2>"$WORK/base-err2"; brc=$?
if [ "$brc" -ne 0 ]; then ok "missing desktops file → loud refusal, no fail-open"; else bad "missing desktops file → loud refusal, no fail-open" "want rc!=0 got rc=0"; fi
assert_contains "refusal names the unreadable desktops file" "$(<"$WORK/base-err2")" "absent-desktops"

echo
echo "  $pass passed, $fail failed"
[ "$fail" -eq 0 ]
