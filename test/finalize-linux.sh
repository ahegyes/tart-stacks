#!/usr/bin/env bash
# Behavioral tests for shared/linux/scripts/99-finalize.sh's SSH-key-gate
# wiring: it must source shared/scripts/authorized-key-lib.sh and call
# assert_authorized_key_safe ahead of authorizing the key, installing NOPASSWD
# sudo, and the irreversible passwd -l. The gate's own accept/refuse behavior
# (every private-key format, the poisoned-comment and compound-file cases) is
# covered in test/authorized-key-lib.sh, driven directly against the library —
# ordering is the property that belongs to the caller, and is all that's
# under test here. Plain bash, no framework.
set -uo pipefail

TEST_DIR=$(cd -P "$(dirname "$0")" >/dev/null 2>&1 && pwd)
REPO=$(cd -P "$TEST_DIR/.." >/dev/null 2>&1 && pwd)
FINALIZE="$REPO/shared/linux/scripts/99-finalize.sh"

pass=0 fail=0
ok()  { pass=$((pass + 1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  FAIL %s\n         %s\n' "$1" "${2:-}"; }

echo "99-finalize (linux) — sources and calls the shared gate, not a reimplementation:"
if grep -qF 'source /tmp/authorized-key-lib.sh' "$FINALIZE"; then
  ok "sources /tmp/authorized-key-lib.sh"
else
  bad "sources /tmp/authorized-key-lib.sh" "no matching source line found"
fi
if grep -qE '^assert_authorized_key_safe .* \|\| exit 1$' "$FINALIZE"; then
  ok "calls assert_authorized_key_safe ... || exit 1"
else
  bad "calls assert_authorized_key_safe ... || exit 1" "no matching call found"
fi
# The gate's own logic must live in the library, not be pasted back in here —
# a reimplementation would silently drift from what test/authorized-key-lib.sh
# actually proves against.
if grep -q -- '-----BEGIN .*PRIVATE KEY-----' "$FINALIZE"; then
  bad "does not reimplement the PEM-armor check inline" \
      "found the armor pattern in $FINALIZE — the gate belongs in authorized-key-lib.sh"
else
  ok "does not reimplement the PEM-armor check inline"
fi
if grep -q -- 'ssh-keygen -l -f' "$FINALIZE"; then
  bad "does not reimplement the parse check inline" \
      "found a direct ssh-keygen -l -f call in $FINALIZE — the gate belongs in authorized-key-lib.sh"
else
  ok "does not reimplement the parse check inline"
fi

# Ordering is the other half of the contract: a gate that ran after the
# install, or after passwd -l, would refuse a key the image had already
# authorized — with no password left to get back in with.
echo "99-finalize (linux) — the gate precedes the install and the lockout:"
# Fixed-string search for the literal, anchored regexes for the two lines
# whose bare form also appears in the header comment. A pattern that matches
# nothing leaves the line empty, which the ordering check below reports
# rather than silently skips.
line_of() { grep -nF -- "$1" "$FINALIZE" | head -n1 | cut -d: -f1; }
line_re() { grep -nE -- "$1" "$FINALIZE" | head -n1 | cut -d: -f1; }
gate_line=$(line_re '^assert_authorized_key_safe .* \|\| exit 1$')
install_line=$(line_of '.ssh/authorized_keys')
lock_line=$(line_re '^passwd -l ')

check_order() { # <earlier-label> <earlier-line> <later-label> <later-line>
  if [ -n "$2" ] && [ -n "$4" ] && [ "$2" -lt "$4" ]; then
    ok "$1 (line $2) precedes $3 (line $4)"
  else
    bad "$1 precedes $3" "got $1=${2:-absent}, $3=${4:-absent}"
  fi
}
check_order "the authorized-key gate"     "$gate_line"    "the authorized_keys install" "$install_line"
check_order "the authorized_keys install" "$install_line" "passwd -l"                   "$lock_line"

printf '\n  %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
