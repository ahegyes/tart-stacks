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
bad() { fail=$((fail + 1)); printf '  FAIL %s\n         expected | %s\n         actual   | %s\n' "$1" "$2" "$3"; }
assert_eq()       { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "$2" "$3"; fi; }
assert_contains() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "contains » $3" "$2" ;; esac; }
assert_absent()   { case "$2" in *"$3"*) bad "$1" "absent » $3" "$2" ;; *) ok "$1" ;; esac; }
check() { # label expected-rc cmd...
  local label="$1" want="$2"; shift 2
  local got=0; "$@" || got=$?
  if [ "$got" -eq "$want" ]; then ok "$label"; else bad "$label" "rc $want" "rc $got"; fi
}

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# Fixture stacks/ tree: two stacks present (dirs no longer carry distro prefix).
mkdir -p "$WORK/stacks/php/scripts" "$WORK/stacks/jvm/scripts"

# Supported-distros fixture used by the pure-helper and main-flow sections.
printf 'fedora\n' > "$WORK/distros"
# A two-distro variant for is_base_image tests that need ubuntu too.
printf 'fedora\nubuntu\n' > "$WORK/distros2"

# Extract the pure helpers from the source and exercise them directly (same
# technique parsing.sh uses for tart-up's parser fns — re-extracts each run so it
# tracks the real source through refactors).
extract_fn() { awk -v fn="$1" 'index($0, fn "() {")==1{p=1} p{print} p && $0=="}"{exit}' "$2"; }
{ extract_fn image_for_stack "$BIN/tart-new"
  echo
  extract_fn list_stacks "$BIN/tart-new"
  echo
  extract_fn stack_exists "$BIN/tart-new"; } > "$WORK/fns.sh"
# shellcheck disable=SC2034  # read as a global by the sourced helpers below
STACKS_DIR="$WORK/stacks"   # list_stacks/stack_exists read this global
# shellcheck source=/dev/null
source "$WORK/fns.sh"

echo "bin/tart-new — pure helpers:"
assert_eq "image_for_stack joins distro-stack" "fedora-php" "$(image_for_stack php fedora)"
assert_eq "image_for_stack ubuntu variant"     "ubuntu-jvm" "$(image_for_stack jvm ubuntu)"
assert_eq "list_stacks lists short tokens sorted" "jvm php" "$(list_stacks | sort | paste -sd' ' -)"
if stack_exists php; then ok "stack_exists true for present stack"; else bad "stack_exists true for present stack" "rc 0" "rc 1"; fi
if stack_exists rust; then bad "stack_exists false for absent stack" "rc 1" "rc 0"; else ok "stack_exists false for absent stack"; fi

# Mock `tart` so list/get output is deterministic and clone/set are recorded.
# Mirrors parsing.sh's fake-tart-on-PATH approach. .Source=="local" is the
# real field tart-new's image_built keys on.
mkdir -p "$WORK/bin"
cat > "$WORK/bin/tart" <<'TART'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$TART_CALLS"
case "$1" in
  list) cat "$TART_LIST_JSON" ;;
  get)  cat "$TART_GET_JSON" 2>/dev/null || echo '{}' ;;
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

{ extract_fn image_built "$BIN/tart-new"; echo; extract_fn vm_exists "$BIN/tart-new"; } > "$WORK/q.sh"
# shellcheck source=/dev/null
source "$WORK/q.sh"

echo "bin/tart-new — tart-querying helpers:"
if PATH="$WORK/bin:$PATH" image_built php fedora; then ok "image_built true when local image present"; else bad "image_built true when local image present" "rc 0" "rc 1"; fi
if PATH="$WORK/bin:$PATH" image_built jvm fedora; then bad "image_built false when only OCI present" "rc 1" "rc 0"; else ok "image_built false when only OCI present"; fi
if PATH="$WORK/bin:$PATH" vm_exists app-a; then ok "vm_exists true for present VM"; else bad "vm_exists true for present VM" "rc 0" "rc 1"; fi
if PATH="$WORK/bin:$PATH" vm_exists nope; then bad "vm_exists false for absent VM" "rc 1" "rc 0"; else ok "vm_exists false for absent VM"; fi

# End-to-end: run the whole script with mocked tart + fixture stacks. Assert on
# exit code, stderr message, and the recorded tart calls.
run_new() { # args... -> stdout; stderr to $WORK/err; exit code in $rc
  rc=0
  PATH="$WORK/bin:$PATH" TART_STACKS_DIR="$WORK/stacks" TART_DISTROS="$WORK/distros" \
    bash "$BIN/tart-new" "$@" >"$WORK/out" 2>"$WORK/err" </dev/null || rc=$?
}

echo "bin/tart-new — main flow:"

# Unknown stack → exit 1, lists available.
run_new app-x rust fedora
assert_eq       "unknown stack exits 1" 1 "$rc"
assert_contains "unknown stack lists available" "$(<"$WORK/err")" "available: jvm, php"

# Unsupported distro → exit 1, mentions "not supported".
run_new app-x php arch
assert_eq       "unsupported distro exits 1" 1 "$rc"
assert_contains "unsupported distro mentions not supported" "$(<"$WORK/err")" "not supported"

# Unbuilt stack, non-interactive → exit 1, prints the build command, no clone.
: > "$TART_CALLS"
run_new app-x jvm fedora
assert_eq       "unbuilt image exits 1 non-interactively" 1 "$rc"
assert_contains "unbuilt error names the image"      "$(<"$WORK/err")" "image 'fedora-jvm' is not built"
assert_contains "unbuilt image prints build command" "$(<"$WORK/err")" "make build STACK=jvm DISTRO=fedora"
assert_absent   "unbuilt image does not clone" "$(<"$TART_CALLS")" "clone"

# Name collision → exit 1, no clone.
: > "$TART_CALLS"
run_new app-a php fedora
assert_eq       "collision exits 1" 1 "$rc"
assert_contains "collision message names the VM" "$(<"$WORK/err")" "'app-a' already exists"
assert_absent   "collision does not clone" "$(<"$TART_CALLS")" "clone"

# Happy path with resources → clones from fedora-php, then tart set.
: > "$TART_CALLS"
run_new web php fedora --cpu 4 --memory 8192 --disk-size 60
assert_eq       "happy path exits 0" 0 "$rc"
assert_contains "clones from the stack image" "$(<"$TART_CALLS")" "clone fedora-php web"
assert_contains "sets resources"              "$(<"$TART_CALLS")" "set web --cpu 4 --memory 8192 --disk-size 60"
assert_contains "prints next-step hint"       "$(<"$WORK/err")"   "next: ssh tart-web"

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

# Bad arity (only 2 positionals, missing distro) → usage, exit 64.
run_new only-one two
assert_eq "missing distro arg exits 64" 64 "$rc"

# ── is_base_image unit tests ─────────────────────────────────────────────────
# Extract from tart-up and exercise directly.
extract_fn is_base_image "$BIN/tart-up" > "$WORK/base-fn.sh"
# shellcheck source=/dev/null
source "$WORK/base-fn.sh"

echo "bin/tart-up — is_base_image:"
check "<distro>-base is a base"        0 is_base_image fedora-base "$WORK/stacks" "$WORK/distros2"
check "ubuntu-base is a base"          0 is_base_image ubuntu-base "$WORK/stacks" "$WORK/distros2"
check "<distro>-<stack> is a base"     0 is_base_image fedora-php  "$WORK/stacks" "$WORK/distros2"
check "ubuntu-jvm is a base"           0 is_base_image ubuntu-jvm  "$WORK/stacks" "$WORK/distros2"
check "plain dev VM not a base"        1 is_base_image app-a       "$WORK/stacks" "$WORK/distros2"
check "hyphenated dev VM not a base"   1 is_base_image web-php     "$WORK/stacks" "$WORK/distros2"
check "unsupported-prefix not a base"    1 is_base_image arch-php    "$WORK/stacks" "$WORK/distros2"

echo
echo "  $pass passed, $fail failed"
[ "$fail" -eq 0 ]
