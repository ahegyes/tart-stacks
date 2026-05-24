#!/usr/bin/env bash
# Characterization tests for the config-line parsing shared in shape by
# bin/tssh (mounts) and bin/tart-ssh-sync (forwards): the
# `<vm-pattern> <rest>` grammar, comment/blank skipping, whitespace
# handling, and vm-pattern matching (`*` | name | comma-list).
#
# Pins observable behavior so the parsing internals can be refactored
# without regressions. Plain bash, no framework — runs anywhere the scripts
# do (and in CI as-is). Run via `script/test` or `bash test/parsing.sh`.

set -uo pipefail

TEST_DIR=$(cd -P "$(dirname "$0")" >/dev/null 2>&1 && pwd)
REPO=$(cd -P "$TEST_DIR/.." >/dev/null 2>&1 && pwd)
BIN="$REPO/bin"

pass=0 fail=0
ok()  { pass=$((pass + 1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  FAIL %s\n         expected | %s\n         actual   | %s\n' "$1" "$2" "$3"; }

assert_eq() { # label expected actual
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "$2" "$3"; fi
}
assert_contains() { # label haystack needle
  case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "contains » $3" "$2" ;; esac
}
assert_absent() { # label haystack needle
  case "$2" in *"$3"*) bad "$1" "absent » $3" "$2" ;; *) ok "$1" ;; esac
}
check() { # label expected-rc cmd...
  local label="$1" want="$2"; shift 2
  local got=0; "$@" || got=$?
  if [ "$got" -eq "$want" ]; then ok "$label"; else bad "$label" "rc $want" "rc $got"; fi
}

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
nl=$'\n'

# ── bin/tart-ssh-sync: forwards parser (exercised via --dry-run) ────────────
# Mock `tart` so the dev-VM list is deterministic. Real path:
# `tart list --format json | jq '.[] | select(.Source=="local") | .Name'`.
mkdir -p "$WORK/bin"
cat > "$WORK/bin/tart" <<'TART'
#!/usr/bin/env bash
[ "$1" = "list" ] && printf '%s\n' '[{"Name":"app-a","Source":"local"},{"Name":"app-b","Source":"local"},{"Name":"fedora-php","Source":"local"},{"Name":"fedora-base","Source":"local"},{"Name":"pulled-img","Source":"oci"}]'
exit 0
TART
chmod +x "$WORK/bin/tart"

SYNC_ERR="$WORK/sync.err"
run_sync() { # forwards-file-content -> stdout of --dry-run (stderr -> $SYNC_ERR)
  printf '%s' "$1" > "$WORK/forwards"
  PATH="$WORK/bin:$PATH" \
  TART_FORWARDS="$WORK/forwards" \
  TART_AGENT_SOCKET="/tmp/agent.sock" \
  TART_SSH_CONFIG_D="$WORK/out" \
    bash "$BIN/tart-ssh-sync" --dry-run 2>"$SYNC_ERR"
}

echo "bin/tart-ssh-sync — forwards parser:"

out=$(run_sync "")
assert_contains  "common block lists both prefixed dev VMs"   "$out" "Host tart-app-a tart-app-b"
assert_contains  "common block sets User admin"               "$out" "User admin"
assert_contains  "host agent socket forwarded into every VM"  "$out" "RemoteForward /home/admin/.ssh/forwarded-agent.sock /tmp/agent.sock"
assert_absent    "stack build artifact excluded (fedora-php)" "$out" "tart-fedora-php"
assert_absent    "intermediate base excluded (fedora-base)"   "$out" "tart-fedora-base"
assert_absent    "OCI image excluded"                         "$out" "pulled-img"

out=$(run_sync "* RemoteForward 27123 127.0.0.1:27123")
assert_contains  "wildcard groups the forward under both hosts" "$out" "# Forwards for pattern: *${nl}Host tart-app-a tart-app-b${nl}"
assert_contains  "wildcard forward line emitted"                "$out" "RemoteForward 27123 127.0.0.1:27123"

out=$(run_sync "app-a RemoteForward 8080 127.0.0.1:8080")
assert_contains  "single name resolves to only its prefixed host" "$out" "# Forwards for pattern: app-a${nl}Host tart-app-a${nl}"
assert_contains  "single-name forward line emitted"               "$out" "RemoteForward 8080 127.0.0.1:8080"

out=$(run_sync "app-a,app-b RemoteForward 9000 127.0.0.1:9000")
assert_contains  "comma-list resolves to both prefixed hosts" "$out" "# Forwards for pattern: app-a,app-b${nl}Host tart-app-a tart-app-b${nl}"

out=$(run_sync "# a comment line${nl}${nl}app-a RemoteForward 7 127.0.0.1:7   # trailing note")
assert_contains  "trailing comment stripped from forward args" "$out" "RemoteForward 7 127.0.0.1:7"
assert_absent    "trailing comment text not emitted"           "$out" "trailing note"

out=$(run_sync "app-a LocalForward 1 2")
assert_contains  "unsupported directive warned to stderr" "$(<"$SYNC_ERR")" "skipping unsupported directive 'LocalForward'"
assert_absent    "unsupported directive not emitted"      "$out" "LocalForward"

out=$(run_sync "ghost RemoteForward 1 2")
assert_absent    "name absent from tart list is dropped" "$out" "tart-ghost"

# ── bin/tssh: mounts parser (dir_args_for_vm / tart_pattern_matches) ─────────
# tssh has no dry-run and its main flow needs a live VM, so pull the two pure
# parsing functions out of the source and exercise them directly. Re-extracts
# every run, so it tracks the real source through refactors.
extract_fn() { # function-name file
  # Match by exact prefix and exact close-brace line — no regex, so it behaves
  # identically across awk flavors (BSD awk on macOS, mawk on the CI runner).
  awk -v fn="$1" 'index($0, fn "() {")==1{p=1} p{print} p && $0=="}"{exit}' "$2"
}
{ extract_fn tart_pattern_matches "$BIN/tssh"; echo; extract_fn dir_args_for_vm "$BIN/tssh"; } > "$WORK/tssh-fns.sh"
# shellcheck source=/dev/null
source "$WORK/tssh-fns.sh"

MNT_ERR="$WORK/mounts.err"
mounts() { # mounts-file-content vm -> stdout of dir_args_for_vm (stderr -> $MNT_ERR)
  printf '%s' "$1" > "$WORK/mounts"
  # dir_args_for_vm (sourced above) reads MOUNTS_CONFIG as a global.
  # shellcheck disable=SC2034
  MOUNTS_CONFIG="$WORK/mounts"
  dir_args_for_vm "$2" 2>"$MNT_ERR"
}

echo "bin/tssh — mounts parser:"

assert_eq "wildcard mount, read-only, share name = path basename" \
  "--dir=dotfiles:/Users/me/dotfiles:ro" "$(mounts '* /Users/me/dotfiles:ro' app-a)"
assert_eq "single-name mount matches its VM" \
  "--dir=project:/Users/me/code/project" "$(mounts 'build-vm /Users/me/code/project' build-vm)"
assert_eq "single-name mount ignored for a different VM" \
  "" "$(mounts 'build-vm /Users/me/code/project' other-vm)"
assert_eq "comma-list mount matches a listed VM" \
  "--dir=data:/srv/data" "$(mounts 'app-a,app-b /srv/data' app-b)"
assert_eq "comma-list mount ignored for an unlisted VM" \
  "" "$(mounts 'app-a,app-b /srv/data' app-c)"
assert_eq "comment and blank lines skipped" \
  "--dir=x:/x" "$(mounts "# a comment${nl}${nl}* /x" app-a)"
assert_eq "trailing comment and whitespace stripped from the path" \
  "--dir=data:/srv/data" "$(mounts '* /srv/data   # my data dir' app-a)"

# The branch the refactor must preserve: a line with a pattern but no path is
# reported and skipped — no --dir emitted.
out=$(mounts 'app-a' app-a)
assert_eq        "no-path line emits no --dir"   "" "$out"
assert_contains  "no-path line warned to stderr" "$(<"$MNT_ERR")" "no path on line, skipping"

echo "bin/tssh — tart_pattern_matches:"
check "'*' matches any VM"              0 tart_pattern_matches '*'     anything
check "exact name matches"             0 tart_pattern_matches app-a   app-a
check "a different name does not match" 1 tart_pattern_matches app-a   app-b
check "comma-list matches a member"     0 tart_pattern_matches 'a,b,c' b
check "comma-list rejects a non-member" 1 tart_pattern_matches 'a,b,c' z

echo
echo "  $pass passed, $fail failed"
[ "$fail" -eq 0 ]
