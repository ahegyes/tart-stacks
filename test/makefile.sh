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
mkdir -p "$SANDBOX/shared/linux" "$SANDBOX/shared/darwin"
cp "$REPO/Makefile" "$SANDBOX/"
cp "$REPO/shared/linux/os" "$REPO/shared/linux/desktops" "$SANDBOX/shared/linux/"
cp "$REPO/shared/darwin/os" "$SANDBOX/shared/darwin/"
cp -R "$REPO/stacks" "$REPO/templates" "$SANDBOX/"

# A second shared/*/os directory, present only in the sandbox, so the PLATFORM
# tests below exercise dispatch across more than one candidate instead of just
# finding shared/linux because it's the only one there. Its comment line
# doubles as the "would match a comment" fixture: "decoytoken" only ever
# appears inside a '#' line, so a token equal to it must still resolve to
# nothing — proving comment-stripping runs before the exact-match check, not
# after.
mkdir -p "$SANDBOX/shared/decoy"
printf '# decoytoken\nrealtoken\n' > "$SANDBOX/shared/decoy/os"

# A THIRD shared/*/os directory sharing one token with the second, so the
# ambiguity gate below has two real files to catch a collision between,
# instead of asserting against a fixture built to look like one.
mkdir -p "$SANDBOX/shared/decoy2"
printf 'collide\n' > "$SANDBOX/shared/decoy2/os"
printf 'collide\n' >> "$SANDBOX/shared/decoy/os"

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

# `-p -q help` prints make's variable database without running any recipe:
# `help` is a real .PHONY target so make has no rule-less-target error to swallow,
# and `-q` skips its body regardless. PLATFORM is simply-expanded (`:=`), so the
# database shows its resolved value rather than the unexpanded `$(shell …)` text.
platform_of() { # OS=value…
  make -C "$SANDBOX" -s -p -q help "$@" 2>/dev/null \
    | sed -n 's/^PLATFORM[[:space:]]*:\{0,1\}=[[:space:]]*//p' | head -1
}
assert_platform() { # label want OS=value…
  local label="$1" want="$2"; shift 2
  local got; got=$(platform_of "$@")
  if [ "$got" = "$want" ]; then ok "$label"; else bad "$label" "want PLATFORM='$want', got '$got'"; fi
}

# Same trick for BASE_IMAGE, which the darwin work adds: `:=`, so `-p` shows
# the resolved repo string, not the unexpanded $(if $(filter …)).
base_image_of() { # OS=value… [MACOS_RELEASE=value] [IMAGE_TAG=value]
  make -C "$SANDBOX" -s -p -q help "$@" 2>/dev/null \
    | sed -n 's/^BASE_IMAGE[[:space:]]*:\{0,1\}=[[:space:]]*//p' | head -1
}
assert_base_image() { # label want OS=value…
  local label="$1" want="$2"; shift 2
  local got; got=$(base_image_of "$@")
  if [ "$got" = "$want" ]; then ok "$label"; else bad "$label" "want BASE_IMAGE='$want', got '$got'"; fi
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

echo "Makefile — check-os:"
assert_rejects "empty OS rejected"        check-os OS=
assert_rejects "unsupported OS rejected"  check-os OS=arch
assert_rejects "OS=bogus still rejected"  check-os OS=bogus
os_cases=0
while IFS= read -r d; do
  os_cases=$((os_cases + 1))
  assert_accepts "shared/linux/os token '$d' accepted" check-os OS="$d"
done < <(grep -vE '^[[:space:]]*(#|$)' "$REPO/shared/linux/os")
if [ "$os_cases" -gt 0 ]; then ok "shared/linux/os contributed $os_cases case(s)"
else bad "shared/linux/os contributed cases" "the file yielded no tokens, so the loop above asserted nothing"; fi

# check-os must not be linux-only: it has to scan every shared/*/os, darwin
# included, or the moment a second platform exists, OS=macos fails the
# membership test before a darwin build ever starts.
darwin_cases=0
while IFS= read -r d; do
  darwin_cases=$((darwin_cases + 1))
  assert_accepts "shared/darwin/os token '$d' accepted" check-os OS="$d"
done < <(grep -vE '^[[:space:]]*(#|$)' "$REPO/shared/darwin/os")
if [ "$darwin_cases" -gt 0 ]; then ok "shared/darwin/os contributed $darwin_cases case(s)"
else bad "shared/darwin/os contributed cases" "the file yielded no tokens, so the loop above asserted nothing"; fi

# A token claimed by two platforms (the decoy/decoy2 fixture's shared
# "collide") must refuse rather than silently build whichever the alphabetical
# glob lists first — the resolver picking darwin over linux for a shared
# fedora token, unnoticed, is the scenario this closes.
assert_rejects "a token claimed by two platforms is refused" check-os OS=collide
gate check-os OS=collide
assert_contains "the ambiguity refusal names the token"          "$(cat "$ERR")" "collide"
assert_contains "the ambiguity refusal names one claiming file"  "$(cat "$ERR")" "shared/decoy/os"
assert_contains "the ambiguity refusal names the other claiming file" "$(cat "$ERR")" "shared/decoy2/os"

# PLATFORM must fail EMPTY, never guess: an empty result turns
# `packer build … $(PLATFORM).pkr.hcl` into `packer build … .pkr.hcl` — a
# wrong-but-plausible command instead of a refusal. check-os's own validity
# check above computes a related fact by a different, hardcoded path
# (shared/linux/os only); these cases exercise the resolver's own shared/*/os
# scan directly, so they'd catch a divergence between the two that a
# gate-only test never would.
echo "Makefile — PLATFORM resolver:"
unset OS   # so "unset entirely" reflects the Makefile's own `?=` default,
               # not whatever the invoking shell happened to export
assert_platform "OS unset entirely resolves to nothing"               ""
assert_platform "OS as an explicit empty string resolves to nothing"  "" OS=
assert_platform "an unsupported OS resolves to nothing"               "" OS=bogus
assert_platform "a token matching only a comment line resolves to nothing" "" OS=decoytoken
assert_platform "the decoy fixture's real token resolves to its own dir"  "decoy" OS=realtoken
# A token claimed by two platforms must resolve to nothing, never to
# whichever file the alphabetical glob happens to list first — a silent
# misroute is worse than an unbuildable cell.
assert_platform "a token claimed by two platforms resolves to nothing, not a guess" "" OS=collide

platform_cases=0
while IFS= read -r d; do
  platform_cases=$((platform_cases + 1))
  assert_platform "shared/linux/os token '$d' resolves to linux" "linux" OS="$d"
done < <(grep -vE '^[[:space:]]*(#|$)' "$REPO/shared/linux/os")
if [ "$platform_cases" -gt 0 ]; then ok "shared/linux/os contributed $platform_cases PLATFORM case(s)"
else bad "shared/linux/os contributed PLATFORM cases" "the file yielded no tokens, so the loop above asserted nothing"; fi

# The glob is alphabetical (darwin sorts before linux) — this is the exact
# ordering the earlier resolver silently broke on the first match to exploit.
darwin_platform_cases=0
while IFS= read -r d; do
  darwin_platform_cases=$((darwin_platform_cases + 1))
  assert_platform "shared/darwin/os token '$d' resolves to darwin" "darwin" OS="$d"
done < <(grep -vE '^[[:space:]]*(#|$)' "$REPO/shared/darwin/os")
if [ "$darwin_platform_cases" -gt 0 ]; then ok "shared/darwin/os contributed $darwin_platform_cases PLATFORM case(s)"
else bad "shared/darwin/os contributed PLATFORM cases" "the file yielded no tokens, so the loop above asserted nothing"; fi

# Cirrus publishes macOS per release rather than under a rolling <os> tag, so
# darwin's BASE_IMAGE can't be derived from OS the way linux's is — these
# cases are what actually proves that split, not just PLATFORM's name for it.
echo "Makefile — BASE_IMAGE:"
assert_base_image "OS=macos resolves to the macos-<release>-base repo (default MACOS_RELEASE)" \
  "ghcr.io/cirruslabs/macos-tahoe-base:latest" OS=macos
assert_base_image "OS=fedora resolves to the plain ghcr.io/cirruslabs/<os> repo" \
  "ghcr.io/cirruslabs/fedora:latest" OS=fedora
assert_base_image "MACOS_RELEASE override changes the resolved repo" \
  "ghcr.io/cirruslabs/macos-sequoia-base:latest" OS=macos MACOS_RELEASE=sequoia
assert_base_image "IMAGE_TAG override carries into the macos repo's tag too" \
  "ghcr.io/cirruslabs/macos-tahoe-base:26" OS=macos IMAGE_TAG=26

# GUI is read by `$(if $(GUI),…)`, where make truthiness would treat GUI=0 as ON.
echo "Makefile — check-gui:"
assert_accepts "GUI unset accepted" check-gui GUI=
assert_accepts "GUI=1 accepted"     check-gui GUI=1
assert_rejects "GUI=0 rejected"     check-gui GUI=0
assert_rejects "GUI=true rejected"  check-gui GUI=true
assert_rejects "GUI=yes rejected"   check-gui GUI=yes

# The macOS desktop is intrinsic to the base image, so darwin has no DE axis
# for GUI=1 to bake — it's a linux-platform flag.
assert_rejects "GUI=1 refused on darwin" check-gui OS=macos GUI=1
gate check-gui OS=macos GUI=1
assert_contains "the darwin GUI refusal explains why, not just refuses" "$(cat "$ERR")" "intrinsic"
assert_accepts "GUI unset is fine on darwin" check-gui OS=macos GUI=

# DE is only meaningful with GUI set, and `DE ?=` picks up the caller's
# environment — so a stray value must not fail a headless target.
echo "Makefile — check-de:"
assert_rejects "GUI=1 with an unsupported DE rejected" check-de GUI=1 DE=cinnamon
assert_accepts "an unsupported DE is ignored without GUI" check-de DE=cinnamon
de_cases=0
while IFS= read -r de; do
  de_cases=$((de_cases + 1))
  assert_accepts "shared/linux/desktops token '$de' accepted with GUI=1" check-de GUI=1 DE="$de"
done < <(grep -vE '^[[:space:]]*(#|$)' "$REPO/shared/linux/desktops")
if [ "$de_cases" -gt 0 ]; then ok "shared/linux/desktops contributed $de_cases case(s)"
else bad "shared/linux/desktops contributed cases" "the file yielded no tokens, so the loop above asserted nothing"; fi

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
  for g in check-stack check-os check-gui check-de; do
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

# The docs targets and the generator's test wiring, pinned from outside the
# files that carry them: `make docs`/`docs-check` must reach script/stack-docs,
# and test/declaration.sh must actually invoke the --check — deleting that
# block would otherwise leave every README block unverified while the rest of
# the declaration suite stays green.
echo "Makefile — the docs surface is wired:"
# Each target must carry its own MODE, not merely name the script — swapped
# modes would rewrite on check and check on write.
if sed -n '/^docs:/,/^$/p' "$REPO/Makefile" | grep -q -- '--write'; then
  ok "make docs runs stack-docs --write"
else
  bad "make docs runs stack-docs --write" "no --write call under the docs target"
fi
if sed -n '/^docs-check:/,/^$/p' "$REPO/Makefile" | grep -q -- '--check'; then
  ok "make docs-check runs stack-docs --check"
else
  bad "make docs-check runs stack-docs --check" "no --check call under the docs-check target"
fi
# Two load-bearing invocations, pinned as WHOLE lines (the drift-control
# fixture calls also name --check, and an unanchored fixed string is
# satisfied by a comment carrying the same text beside a gutted call): the
# bare call covers every stacks/*/ README, the $SCAF call the scaffold.
# shellcheck disable=SC2016  # the patterns match LITERAL source text incl. $()
if grep -qxF 'if out=$("$REPO/script/stack-docs" --check 2>&1); then' "$REPO/test/declaration.sh"; then
  ok "test/declaration.sh --checks every stack README"
else
  bad "test/declaration.sh --checks every stack README" "the all-stacks stack-docs --check line is missing or reshaped"
fi
# shellcheck disable=SC2016  # the pattern matches LITERAL source text incl. $()
if grep -qxF 'if out=$("$REPO/script/stack-docs" --check "$SCAF" 2>&1); then' "$REPO/test/declaration.sh"; then
  ok "test/declaration.sh --checks the materialized scaffold"
else
  bad "test/declaration.sh --checks the materialized scaffold" "the scaffold stack-docs --check line is missing or reshaped"
fi

# The guard that makes every case above safe: a token the gates accept really does
# get scaffolded, and it lands in the copy.
echo "Makefile — scaffold writes only inside the sandbox:"
assert_accepts "scaffold of a fresh valid token succeeds" scaffold STACK=probe
if [ -f "$SANDBOX/stacks/probe/README.md" ]; then ok "scaffold wrote into the sandbox copy"
else bad "scaffold wrote into the sandbox copy" "no $SANDBOX/stacks/probe/README.md"; fi
# The tools declaration is what script/smoke probes and the gate checks hold
# to — a scaffold without one stamps a stack that can never pass either.
if [ -f "$SANDBOX/stacks/probe/tools" ]; then ok "scaffold stamped the tools declaration"
else bad "scaffold stamped the tools declaration" "no $SANDBOX/stacks/probe/tools"; fi
if grep -q '__STACK__' "$SANDBOX/stacks/probe/tools" 2>/dev/null; then
  bad "the stamped tools file has no unsubstituted __STACK__" "placeholder survived"
else ok "the stamped tools file has no unsubstituted __STACK__"; fi
if [ -e "$REPO/stacks/probe" ]; then bad "scaffold left the checkout untouched" "$REPO/stacks/probe exists"
else ok "scaffold left the checkout untouched"; fi

printf '\n  %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
