#!/usr/bin/env bash
# Lives in shared/scripts/ rather than a platform tree because it runs verbatim
# on every platform this repo builds. That directory's contract is "both
# platforms", not "unmarked" — a platform-specific script belongs under
# shared/<platform>/scripts/.
# authorized-key-lib.sh — the anti-lockout gate a 99-finalize.sh sources before
# authorizing an SSH public key and, later in the same script, doing anything
# irreversible to password auth.
#
# SOURCED, not run: the Packer template uploads this to
# /tmp/authorized-key-lib.sh (a `file` provisioner) and the caller sources it.

# assert_authorized_key_safe <path> — HARD GATE: refuse unless <path> exists,
# holds no PRIVATE key material, and parses as a valid SSH public key. Callers
# run this ahead of authorizing the key and any irreversible lockdown that
# follows (e.g. locking the provisioned account's password) — a bad key
# accepted at that point leaves no way back in.
#
# The private-key check runs ahead of the parse check because `ssh-keygen -l
# -f` prints a fingerprint and exits 0 for a private key too — plain,
# passphrase-protected, PEM and PKCS8 alike — so the parse check alone would
# authorize one. It matches the WHOLE PEM armor line (`-----BEGIN .*PRIVATE
# KEY-----`), not the bare words "PRIVATE KEY": a public key's comment field
# is free text, and a comment that happens to read "PRIVATE KEY" carries no
# "-----BEGIN" prefix, so it does not match. And the match is NOT anchored to
# the start of a line: an anchor would miss an indented private block pasted
# below a valid pubkey line — a compound file the parse check alone accepts,
# since `ssh-keygen -l -f` exits 0 when ANY line of the file parses as a key,
# not merely the first (measured on OpenSSH 10.2: garbage on line 1 followed by
# a valid pubkey on line 2 still exits 0).
#
# Takes the key path as an argument rather than a fixed location, so the same
# gate serves every platform's upload destination and can be driven against
# test fixtures. Error messages name the path given, not a caller's build
# variable — the library has no visibility into which one populated it.
assert_authorized_key_safe() {
  local key_path="$1"

  if [ ! -f "$key_path" ]; then
    echo "ERROR: SSH public key not found at ${key_path}. Did the upload provisioner run?" >&2
    return 1
  fi

  if grep -q -- '-----BEGIN .*PRIVATE KEY-----' "$key_path"; then
    echo "ERROR: ${key_path} holds a PRIVATE key. Refusing to proceed (it would authorize no one and ship the private half into every clone) — point the build at the matching .pub file instead." >&2
    return 1
  fi

  if ! ssh-keygen -l -f "$key_path" >/dev/null 2>&1; then
    echo "ERROR: ${key_path} is not a valid SSH public key. Refusing to proceed — an unparseable key authorizes no one and would lock the provisioned account out once password auth is disabled." >&2
    return 1
  fi
}
