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
FINALIZE="$REPO/shared/linux/scripts/99-finalize.sh"

pass=0 fail=0
ok()  { pass=$((pass + 1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  FAIL %s\n         %s\n' "$1" "${2:-}"; }
assert_eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "want » $2 « got » $3 «"; fi; }

WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT

# The gate itself, lifted out of the script and run for real — not reimplemented.
# A copy of the logic here would stay green while the shipped branch lost its
# `exit 1`; this executes the shipped branch, so its control flow is under test
# too. Only the input path is rewritten, from the fixed /tmp upload location to
# the fixture, which is what makes the block runnable off a build host.
GATE="$WORK/gate.sh"
# shellcheck disable=SC2016  # the sed replacement writes a literal "$1" INTO the
# extracted block, for that block to expand — not for this shell
awk '
  /^if grep -q .* \/tmp\/authorized_key\.pub; then$/ { emit=1 }
  emit { print }
  emit && /^fi$/ { seen++ }
  seen==2 { exit }
' "$FINALIZE" | sed 's|/tmp/authorized_key.pub|"$1"|g' > "$GATE"

# Both gates must have come across, or every case below would pass vacuously.
if [ "$(grep -c '^if ' "$GATE")" -eq 2 ] && grep -q 'exit 1' "$GATE"; then
  ok "lifted both gates out of 99-finalize.sh ($(grep -c . "$GATE") lines)"
else
  bad "lifted both gates out of 99-finalize.sh" \
      "extraction produced $(grep -c '^if ' "$GATE") if-block(s) and $(grep -c 'exit 1' "$GATE") exit(s) — the gate moved or changed shape"
  printf '\n  %d passed, %d failed\n' "$pass" "$fail"
  exit 1
fi

# key_verdict <file> — `accept`, `private` or `unparseable`, from the shipped
# block's own exit status and stderr.
key_verdict() {
  local out rc=0
  # `.` with arguments sets the sourced block's own $1 to the fixture — without
  # them it would inherit this wrapper's, and grep the gate file against itself.
  out=$(bash -c '. "$1" "$2"' _ "$GATE" "$1" 2>&1) || rc=$?
  if [ "$rc" -eq 0 ]; then printf 'accept'; return; fi
  case "$out" in
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
# A valid pubkey line followed by a private block — the parse check sees only the
# first line and exits 0, so the armor match is the only thing that can refuse it.
# Indented as well as flush, because a line-anchored pattern misses the indented
# form and `install` copies the WHOLE file into authorized_keys.
{ cat "$WORK/plain.pub"; cat "$WORK/plain"; } > "$WORK/compound"
{ cat "$WORK/plain.pub"; sed 's/^/    /' "$WORK/plain"; } > "$WORK/compound-indented"

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

echo "99-finalize — a pubkey with a private block appended is still refused:"
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

# Ordering is the other half of the contract: a gate that ran after the install,
# or after `passwd -l`, would refuse a key the image had already authorized —
# with no password left to get back in with.
echo "99-finalize — both gates precede the install and the lockout:"
# Fixed-string search for the literals, anchored regexes for the two lines whose
# bare form also appears in the header comment. A pattern that matched nothing
# leaves the line empty, which the ordering check below reports rather than skips.
line_of() { grep -nF -- "$1" "$FINALIZE" | head -n1 | cut -d: -f1; }
line_re() { grep -nE -- "$1" "$FINALIZE" | head -n1 | cut -d: -f1; }
gate_private=$(line_re '^if grep -q .* /tmp/authorized_key\.pub; then$')
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
