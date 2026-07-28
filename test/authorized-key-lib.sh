#!/usr/bin/env bash
# Characterization tests for shared/scripts/authorized-key-lib.sh's
# assert_authorized_key_safe — the one check standing between a mis-pointed
# SSH-key upload and an image that authorizes nobody, run by every platform's
# 99-finalize.sh two steps before an irreversible password lock. Sources the
# library and calls the real function against fixtures — not a
# reimplementation, so a weakened grep pattern or a dropped `return 1` shows
# up here. Plain bash, no framework.
set -uo pipefail

TEST_DIR=$(cd -P "$(dirname "$0")" >/dev/null 2>&1 && pwd)
REPO=$(cd -P "$TEST_DIR/.." >/dev/null 2>&1 && pwd)
# shellcheck source=/dev/null
source "$REPO/shared/scripts/authorized-key-lib.sh"

pass=0 fail=0
ok()  { pass=$((pass + 1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  FAIL %s\n         %s\n' "$1" "${2:-}"; }
assert_eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "want » $2 « got » $3 «"; fi; }

WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT

# Source-order characterization: the existence check must run before the
# private-key check, which must run before the parse check. Both later checks
# independently exit 1, so this ordering is not externally observable from
# key_verdict alone (a private key refused as "private" looks the same
# whichever check runs first) — this is the source of that guarantee, not a
# restatement of it.
LIB="$REPO/shared/scripts/authorized-key-lib.sh"
line_re() { grep -nE -- "$1" "$LIB" | head -n1 | cut -d: -f1; }
# shellcheck disable=SC2016  # the literal `\$key_path` is grep's ERE for the
# library's own source text, not a variable this shell should expand
exists_line=$(line_re '^  if \[ ! -f "\$key_path" \]; then$')
private_line=$(line_re "^  if grep -q .* \\\"\\\$key_path\\\"; then\$")
# shellcheck disable=SC2016  # same as exists_line above: matches source text, not an expansion
parse_line=$(line_re '^  if ! ssh-keygen -l -f "\$key_path"')
check_order() { # <earlier-label> <earlier-line> <later-label> <later-line>
  if [ -n "$2" ] && [ -n "$4" ] && [ "$2" -lt "$4" ]; then
    ok "$1 (line $2) precedes $3 (line $4)"
  else
    bad "$1 precedes $3" "got $1=${2:-absent}, $3=${4:-absent}"
  fi
}
echo "assert_authorized_key_safe — the checks run in a fixed order:"
check_order "the existence check"   "$exists_line"  "the private-key check" "$private_line"
check_order "the private-key check" "$private_line" "the parse check"       "$parse_line"

# key_verdict <file> — `accept`, `private`, `missing` or `unparseable`, from
# assert_authorized_key_safe's own exit status and stderr.
key_verdict() {
  local out rc=0
  out=$(assert_authorized_key_safe "$1" 2>&1) || rc=$?
  if [ "$rc" -eq 0 ]; then printf 'accept'; return; fi
  case "$out" in
    *"not found at"*)                 printf 'missing' ;;
    *"holds a PRIVATE key"*)          printf 'private' ;;
    *"not a valid SSH public key"*)   printf 'unparseable' ;;
    *)                                printf 'refused-unknown: %s' "$out" ;;
  esac
}

# Every private-key format ssh-keygen will emit, plus the two controls. The whole
# reason this gate exists: `ssh-keygen -l -f` prints a fingerprint and exits 0 for
# all four private forms, so the parse check alone authorizes them.
ssh-keygen -q -t ed25519 -N ''       -C plain    -f "$WORK/plain"    >/dev/null
ssh-keygen -q -t ed25519 -N 'sekrit' -C withpass -f "$WORK/withpass" >/dev/null
ssh-keygen -q -t rsa -b 2048 -m PEM   -N '' -C pem   -f "$WORK/pem"   >/dev/null
ssh-keygen -q -t rsa -b 2048 -m PKCS8 -N '' -C pkcs8 -f "$WORK/pkcs8" >/dev/null
printf 'not a key at all\n' > "$WORK/junk"
: > "$WORK/empty"
# A public key's comment is free text. One reading "PRIVATE KEY" must not abort a
# 20-minute build at its last step.
ssh-keygen -q -t ed25519 -N '' -C 'backup of PRIVATE KEY' -f "$WORK/poisoned" >/dev/null
# A valid pubkey line followed by a private block — the parse check exits 0 when
# ANY line parses as a key, so the armor match is the only thing that can refuse
# it.
# Indented as well as flush, because a line-anchored pattern misses the indented
# form and 99-finalize.sh's `install` copies the WHOLE file into authorized_keys.
{ cat "$WORK/plain.pub"; cat "$WORK/plain"; } > "$WORK/compound"
{ cat "$WORK/plain.pub"; sed 's/^/    /' "$WORK/plain"; } > "$WORK/compound-indented"

echo "assert_authorized_key_safe — the file must exist:"
assert_eq "a path with nothing there → refused" "missing" "$(key_verdict "$WORK/does-not-exist")"

echo "assert_authorized_key_safe — the private half is refused in every format:"
for form in plain withpass pem pkcs8; do
  assert_eq "$form private key → refused" "private" "$(key_verdict "$WORK/$form")"
  # Named so the premise stays visible: the parse check cannot substitute.
  if ssh-keygen -l -f "$WORK/$form" >/dev/null 2>&1; then
    ok "$form private key → the parse check alone would have accepted it"
  else
    bad "$form private key → the parse check alone would have accepted it" \
        "ssh-keygen -l -f rejected it, so this fixture no longer proves the gate is needed"
  fi
done

echo "assert_authorized_key_safe — public keys are accepted, junk is not:"
for form in plain withpass pem pkcs8; do
  assert_eq "$form.pub → accepted" "accept" "$(key_verdict "$WORK/$form.pub")"
done
assert_eq "a pubkey whose COMMENT says PRIVATE KEY → accepted" "accept" "$(key_verdict "$WORK/poisoned.pub")"
assert_eq "junk → unparseable"  "unparseable" "$(key_verdict "$WORK/junk")"

echo "assert_authorized_key_safe — a pubkey with a private block appended is still refused:"
for form in compound compound-indented; do
  assert_eq "$form → refused" "private" "$(key_verdict "$WORK/$form")"
  if ssh-keygen -l -f "$WORK/$form" >/dev/null 2>&1; then
    ok "$form → the parse check alone would have accepted it"
  else
    bad "$form → the parse check alone would have accepted it" \
        "ssh-keygen -l -f rejected it, so this fixture no longer proves the armor match is needed"
  fi
done
assert_eq "empty file → unparseable" "unparseable" "$(key_verdict "$WORK/empty")"

printf '\n  %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
