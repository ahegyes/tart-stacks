#!/usr/bin/env bash
# Behavioral tests for 99-finalize.sh's anti-lockout key gate — the one check
# standing between a mis-pointed var.ssh_pubkey_path and an image that authorizes
# nobody, two steps before an irreversible `passwd -l`. The rest of the script
# needs a booted guest (dnf/apt, systemd, visudo), so only this gate is driven
# here; its grep pattern is READ OUT of the script rather than restated, so
# weakening it changes what these cases do. Plain bash, no framework.
set -uo pipefail

TEST_DIR=$(cd -P "$(dirname "$0")" >/dev/null 2>&1 && pwd)
REPO=$(cd -P "$TEST_DIR/.." >/dev/null 2>&1 && pwd)
FINALIZE="$REPO/shared/scripts/99-finalize.sh"

pass=0 fail=0
ok()  { pass=$((pass + 1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  FAIL %s\n         %s\n' "$1" "${2:-}"; }
assert_eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "want » $2 « got » $3 «"; fi; }

WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT

# The pattern the shipped gate greps for. Extracted, not copied: a test carrying
# its own copy would keep passing while the real gate was weakened.
PRIVATE_PATTERN=$(sed -n "s/^if grep -q '\(.*\)' \/tmp\/authorized_key.pub; then\$/\1/p" "$FINALIZE")
if [ -n "$PRIVATE_PATTERN" ]; then
  ok "extracted the private-key pattern from 99-finalize.sh"
else
  bad "extracted the private-key pattern from 99-finalize.sh" \
      "no 'grep -q ... /tmp/authorized_key.pub' line found — the gate moved or changed shape"
  printf '\n  %d passed, %d failed\n' "$pass" "$fail"
  exit 1
fi

# key_verdict <file> — `accept`, `private` or `unparseable`, running the two gates
# in the order 99-finalize.sh runs them.
key_verdict() {
  if grep -q "$PRIVATE_PATTERN" "$1"; then printf 'private'; return; fi
  if ! ssh-keygen -l -f "$1" >/dev/null 2>&1; then printf 'unparseable'; return; fi
  printf 'accept'
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

echo "99-finalize — the private half is refused in every format:"
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

echo "99-finalize — public keys are accepted, junk is not:"
for form in plain withpass pem pkcs8; do
  assert_eq "$form.pub → accepted" "accept" "$(key_verdict "$WORK/$form.pub")"
done
assert_eq "a pubkey whose COMMENT says PRIVATE KEY → accepted" "accept" "$(key_verdict "$WORK/poisoned.pub")"
assert_eq "junk → unparseable"  "unparseable" "$(key_verdict "$WORK/junk")"
assert_eq "empty file → unparseable" "unparseable" "$(key_verdict "$WORK/empty")"

# Ordering is the other half of the contract: a gate that ran after the install,
# or after `passwd -l`, would refuse a key the image had already authorized —
# with no password left to get back in with.
echo "99-finalize — both gates precede the install and the lockout:"
# Fixed-string search for the three literals (one of which is itself a regex),
# and an anchored one for `passwd -l`, whose bare form also appears in the header
# comment. A pattern that matched nothing would leave the line empty, which the
# ordering check below reports rather than skips.
line_of() { grep -nF -- "$1" "$FINALIZE" | head -n1 | cut -d: -f1; }
line_re() { grep -nE -- "$1" "$FINALIZE" | head -n1 | cut -d: -f1; }
gate_private=$(line_of "grep -q '$PRIVATE_PATTERN'")
gate_parse=$(line_of 'ssh-keygen -l -f /tmp/authorized_key.pub')
install_line=$(line_of '.ssh/authorized_keys')
lock_line=$(line_re '^passwd -l ')

check_order() { # <earlier-label> <earlier-line> <later-label> <later-line>
  if [ -n "$2" ] && [ -n "$4" ] && [ "$2" -lt "$4" ]; then
    ok "$1 (line $2) precedes $3 (line $4)"
  else
    bad "$1 precedes $3" "got $1=${2:-absent}, $3=${4:-absent}"
  fi
}
check_order "the private-key gate"        "$gate_private" "the parse check"             "$gate_parse"
check_order "the parse check"             "$gate_parse"   "the authorized_keys install" "$install_line"
check_order "the authorized_keys install" "$install_line" "passwd -l"                   "$lock_line"

printf '\n  %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
