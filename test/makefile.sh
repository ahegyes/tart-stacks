#!/usr/bin/env bash
# Behavioral tests for the Makefile's check-* gates. They are the only thing
# standing between a mistyped selector and `bootstrap`'s destructive base
# re-clone (`tart delete` + `tart clone`), and nothing else in the suite runs
# make. Only the gate targets are invoked — never build/rebuild/bootstrap/smoke —
# so no VM, image or network is touched. Plain bash, no framework.
set -uo pipefail

TEST_DIR=$(cd -P "$(dirname "$0")" >/dev/null 2>&1 && pwd)
REPO=$(cd -P "$TEST_DIR/.." >/dev/null 2>&1 && pwd)

pass=0 fail=0
ok()  { pass=$((pass + 1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  FAIL %s\n         %s\n' "$1" "${2:-}"; }
assert_contains() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "want » $3 « in: $2" ;; esac; }

WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
ERR="$WORK/err"

# `make` runs against a COPY of the repo, never the checkout. `scaffold` writes a
# stack directory for any token the gates let through, so a case that ever stopped
# being refused — or a gate someone disconnects while testing one — would leave
# that directory in the developer's tree and in CI's stacks/* matrix. Copying is
# what makes the blast radius the tmpdir. The copy is made fresh from the real
# Makefile each run, so a deliberate mutation of it still shows up here.
SANDBOX="$WORK/repo"
mkdir -p "$SANDBOX/shared"
cp "$REPO/Makefile" "$SANDBOX/"
cp "$REPO/shared/distros" "$REPO/shared/desktops" "$SANDBOX/shared/"
cp -R "$REPO/stacks" "$REPO/templates" "$SANDBOX/"

gate() { # <target> <VAR=VALUE…> — rc in $rc, stderr in $ERR
  local target="$1"; shift
  rc=0
  make -C "$SANDBOX" "$target" "$@" >/dev/null 2>"$ERR" || rc=$?
}
assert_rejects() { # label target VAR=VALUE…
  local label="$1"; shift
  gate "$@"
  if [ "$rc" -ne 0 ]; then ok "$label"; else bad "$label" "want a nonzero exit, got 0"; fi
}
assert_accepts() { # label target VAR=VALUE…
  local label="$1"; shift
  gate "$@"
  if [ "$rc" -eq 0 ]; then ok "$label"; else bad "$label" "want exit 0, got $rc: $(head -1 "$ERR")"; fi
}

# The token gate is shared by check-stack and scaffold. `STACK=.` is the case that
# motivated sharing it: it satisfies a `[ -d stacks/$(STACK) ]` test, so before the
# gate it reached bootstrap's base re-clone and only Packer's own validation
# rejected it — after the destructive part had already run.
echo "Makefile — check-stack-token:"
assert_rejects "empty STACK rejected"            check-stack-token STACK=
assert_rejects "STACK=. rejected"                check-stack-token STACK=.
assert_rejects "STACK=.. rejected"               check-stack-token STACK=..
assert_rejects "STACK with a slash rejected"     check-stack-token STACK=php/x
assert_rejects "STACK with an ampersand rejected" check-stack-token STACK='a&b'
assert_rejects "STACK with a space rejected"     check-stack-token STACK='a b'
assert_rejects "uppercase STACK rejected"        check-stack-token STACK=PHP
assert_rejects "hyphenated STACK rejected"       check-stack-token STACK=my-stack
assert_accepts "a bare lowercase token accepted" check-stack-token STACK=php
assert_accepts "digits accepted"                 check-stack-token STACK=py3

gate check-stack-token STACK=.
assert_contains "the token refusal names the value" "$(cat "$ERR")" "got '.'"
gate check-stack-token STACK=
assert_contains "the empty refusal names both callers" "$(cat "$ERR")" "make scaffold"

# check-stack adds "the directory exists" on top of the shared token gate — and
# must not accept a token the shared gate rejects.
echo "Makefile — check-stack:"
assert_accepts "an existing stack passes"        check-stack STACK=php
assert_rejects "a nonexistent stack is rejected" check-stack STACK=nosuchstack
assert_rejects "check-stack still applies the token gate" check-stack STACK=.
gate check-stack STACK=nosuchstack
assert_contains "the missing-stack refusal lists what exists" "$(cat "$ERR")" "php"

echo "Makefile — check-distro:"
assert_rejects "empty DISTRO rejected"       check-distro DISTRO=
assert_rejects "unsupported DISTRO rejected" check-distro DISTRO=arch
distro_cases=0
while IFS= read -r d; do
  distro_cases=$((distro_cases + 1))
  assert_accepts "shared/distros token '$d' accepted" check-distro DISTRO="$d"
done < <(grep -vE '^[[:space:]]*(#|$)' "$REPO/shared/distros")
if [ "$distro_cases" -gt 0 ]; then ok "shared/distros contributed $distro_cases case(s)"
else bad "shared/distros contributed cases" "the file yielded no tokens, so the loop above asserted nothing"; fi

# GUI is read by `$(if $(GUI),…)`, where make truthiness would treat GUI=0 as ON.
echo "Makefile — check-gui:"
assert_accepts "GUI unset accepted" check-gui GUI=
assert_accepts "GUI=1 accepted"     check-gui GUI=1
assert_rejects "GUI=0 rejected"     check-gui GUI=0
assert_rejects "GUI=true rejected"  check-gui GUI=true
assert_rejects "GUI=yes rejected"   check-gui GUI=yes

# DE is only meaningful with GUI set, and `DE ?=` picks up the caller's
# environment — so a stray value must not fail a headless target.
echo "Makefile — check-de:"
assert_rejects "GUI=1 with an unsupported DE rejected" check-de GUI=1 DE=cinnamon
assert_accepts "an unsupported DE is ignored without GUI" check-de DE=cinnamon
de_cases=0
while IFS= read -r de; do
  de_cases=$((de_cases + 1))
  assert_accepts "shared/desktops token '$de' accepted with GUI=1" check-de GUI=1 DE="$de"
done < <(grep -vE '^[[:space:]]*(#|$)' "$REPO/shared/desktops")
if [ "$de_cases" -gt 0 ]; then ok "shared/desktops contributed $de_cases case(s)"
else bad "shared/desktops contributed cases" "the file yielded no tokens, so the loop above asserted nothing"; fi

echo "Makefile — scaffold refuses to overwrite:"
assert_rejects "scaffold over an existing stack rejected" scaffold STACK=php
gate scaffold STACK=php
assert_contains "scaffold names the directory it will not clobber" "$(cat "$ERR")" "stacks/php/ already exists"
# `STACK=.` would be refused by the existing-directory guard as well, proving
# nothing about the wiring. An uppercase token has no directory of its own, so
# only the token gate can be what rejects it — and the message says which did.
gate scaffold STACK=Foo
assert_contains "scaffold rejects an invalid token via the shared gate" "$(cat "$ERR")" "must be a lowercase alphanumeric token"

# Behavioural tests cannot reach build/rebuild past their gates without risking
# the destructive `bootstrap` recipe, so the wiring itself is asserted from the
# makefile: these prerequisites are what keep a bad selector away from
# `tart delete` + `tart clone`.
echo "Makefile — the destructive targets keep their gates:"
prereqs_of() { sed -n "s/^$1:[[:space:]]*//p" "$REPO/Makefile" | head -n1; }
for target in build rebuild smoke; do
  line="$(prereqs_of "$target")"
  # A loop variable named `gate` would shadow the helper above for a reader.
  for g in check-stack check-distro check-gui check-de; do
    case " $line " in
      *" $g "*) ok "$target requires $g" ;;
      *)         bad "$target requires $g" "prerequisites are: ${line:-<none>}" ;;
    esac
  done
done
for target in check-stack scaffold; do
  line="$(prereqs_of "$target")"
  case " $line " in
    *" check-stack-token "*) ok "$target requires check-stack-token" ;;
    *)                       bad "$target requires check-stack-token" "prerequisites are: ${line:-<none>}" ;;
  esac
done

# The guard that makes every case above safe: a token the gates accept really does
# get scaffolded, and it lands in the copy.
echo "Makefile — scaffold writes only inside the sandbox:"
assert_accepts "scaffold of a fresh valid token succeeds" scaffold STACK=probe
if [ -f "$SANDBOX/stacks/probe/README.md" ]; then ok "scaffold wrote into the sandbox copy"
else bad "scaffold wrote into the sandbox copy" "no $SANDBOX/stacks/probe/README.md"; fi
if [ -e "$REPO/stacks/probe" ]; then bad "scaffold left the checkout untouched" "$REPO/stacks/probe exists"
else ok "scaffold left the checkout untouched"; fi

printf '\n  %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
