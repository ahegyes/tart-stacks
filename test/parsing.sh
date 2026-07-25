#!/usr/bin/env bash
# Characterization tests for the config-line parsing shared in shape by
# bin/tart-up (mounts) and bin/tart-ssh-sync (forwards): the
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
bad() { fail=$((fail + 1)); printf '  FAIL %s\n         %s\n' "$1" "${2:-}"; }

assert_eq() { # label expected actual
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "want » $2 « got » $3 «"; fi
}
assert_contains() { # label haystack needle
  case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "want » contains » $3 « got » $2 «" ;; esac
}
assert_absent() { # label haystack needle
  case "$2" in *"$3"*) bad "$1" "want » absent » $3 « got » $2 «" ;; *) ok "$1" ;; esac
}
check() { # label expected-rc cmd...
  local label="$1" want="$2"; shift 2
  local got=0; "$@" || got=$?
  if [ "$got" -eq "$want" ]; then ok "$label"; else bad "$label" "want » rc $want « got » rc $got «"; fi
}

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
nl=$'\n'

# ── bin/tart-ssh-sync: forwards parser (exercised via --dry-run) ────────────
# Mock `tart` so the script's `command -v tart` resolves (it bakes that path
# into the generated ProxyCommand). The generator no longer reads `tart list`,
# so the mock's output is irrelevant — only its presence on PATH matters.
mkdir -p "$WORK/bin"
cat > "$WORK/bin/tart" <<'TART'
#!/usr/bin/env bash
exit 0
TART
chmod +x "$WORK/bin/tart"

SYNC_ERR="$WORK/sync.err"
# TART_NC_BIN is cleared so the baked-nc assertion sees the script's own
# /usr/bin/nc default even when the caller's environment overrides the seam.
run_sync() { # forwards-file-content -> stdout of --dry-run (stderr -> $SYNC_ERR)
  printf '%s' "$1" > "$WORK/forwards"
  : > "$WORK/ssh-agents"   # empty by default; ssh-agents tests below pass their own
  PATH="$WORK/bin:$PATH" \
  TART_NC_BIN='' \
  TART_FORWARDS="$WORK/forwards" \
  TART_SSH_AGENTS="$WORK/ssh-agents" \
  TART_SSH_CONFIG_D="$WORK/out" \
    bash "$BIN/tart-ssh-sync" --dry-run 2>"$SYNC_ERR"
}
run_sync_with_agents() { # ssh-agents-content -> stdout of --dry-run with empty forwards
  printf '%s' "$1" > "$WORK/ssh-agents"
  : > "$WORK/forwards"
  PATH="$WORK/bin:$PATH" \
  TART_NC_BIN='' \
  TART_FORWARDS="$WORK/forwards" \
  TART_SSH_AGENTS="$WORK/ssh-agents" \
  TART_SSH_CONFIG_D="$WORK/out" \
    bash "$BIN/tart-ssh-sync" --dry-run 2>"$SYNC_ERR"
}

echo "bin/tart-ssh-sync — forwards parser:"

out=$(run_sync "")
assert_contains  "common block uses the tart-* wildcard"       "$out" "Host tart-*"
assert_contains  "common block sets User admin"                "$out" "User admin"
assert_contains  "common block sets SSH keepalive interval"    "$out" "ServerAliveInterval 15"
assert_contains  "common block caps unanswered keepalives"     "$out" "ServerAliveCountMax 3"
assert_contains  "ProxyCommand resolves the IP at connect time" "$out" "ProxyCommand /bin/sh -c"
assert_contains  "ProxyCommand pins the system nc"             "$out" "/usr/bin/nc"
assert_contains  "auto-start Match gates on interactive shell" "$out" "Match host tart-* sessiontype shell exec"
assert_contains  "auto-start Match gates on a controlling terminal" "$out" "( : </dev/tty )"
assert_contains  "auto-start Match passes tart-up + %n positionally" "$out" "/tart-up' %n\""
assert_absent    "auto-start Match keeps tart-up + %n out of the sh -c body" "$out" "tart-up %n"
assert_absent    "empty ssh-agents emits no per-VM ForwardAgent" "$out" "ForwardAgent"

out=$(run_sync "* RemoteForward 27123 127.0.0.1:27123")
assert_contains  "wildcard forward grouped under the tart-* host" "$out" "# Forwards for pattern: *${nl}Host tart-*${nl}"
assert_contains  "wildcard forward line emitted"                  "$out" "RemoteForward 27123 127.0.0.1:27123"

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

# A RemoteForward with no arguments would emit a bare directive — an OpenSSH
# fatal for the whole generated file — so it is skipped, not emitted.
out=$(run_sync "app-a RemoteForward${nl}app-b RemoteForward 8080 127.0.0.1:8080")
assert_contains  "no-args RemoteForward warned with file:line" "$(<"$SYNC_ERR")" "$WORK/forwards:1: skipping 'RemoteForward' with no arguments"
assert_absent    "no-args RemoteForward emits no Host block"   "$out" "Host tart-app-a"
assert_absent    "no bare RemoteForward directive emitted"     "$out" "RemoteForward${nl}"
assert_contains  "well-formed sibling forward still emitted"   "$out" "RemoteForward 8080 127.0.0.1:8080"

# A forward for a VM that doesn't exist yet is emitted verbatim (no `tart list`
# check) — it stays inert in ssh_config until that VM is cloned.
out=$(run_sync "ghost RemoteForward 1 2")
assert_contains  "forward for a not-yet-cloned VM is emitted verbatim" "$out" "Host tart-ghost"

# The pattern grammar is exactly `*` | name | comma-list: a partial glob would
# land in the Host line as a live OpenSSH wildcard and silently widen the
# forward to every matching VM. Reserved-prefix elements fail the same gate.
out=$(run_sync "app-* RemoteForward 1 2")
assert_absent    "partial-glob pattern is not emitted"   "$out" "Host tart-app-*"
assert_contains  "partial-glob pattern warned + skipped" "$(<"$SYNC_ERR")" "pattern 'app-*'"
out=$(run_sync "tart-x RemoteForward 1 2")
assert_absent    "reserved-prefix pattern is not emitted" "$out" "Host tart-tart-x"

echo "bin/tart-ssh-sync — ssh-agents parser:"

# The ssh-agents file is 3-column: `<vm> <agent> <host-socket>`. The host-socket
# path is supplied per line so tart-stacks doesn't bake in any caller's path
# convention — we test by passing arbitrary paths and asserting they appear
# verbatim in the emitted Host blocks. Agent names below (`alpha`, `beta`)
# are arbitrary identifiers chosen for the tests — the file format places
# no semantic on the agent string.

# Single VM, single agent: per-VM Host block with one ForwardAgent at the
# given host socket. No RemoteForward emitted (only one agent — no additional
# sockets to expose at /run/tart/agent-<name>.sock).
out=$(run_sync_with_agents "vm-a alpha /tmp/sock-alpha")
assert_contains  "single-VM block: Host tart-<name>"          "$out" "Host tart-vm-a"
assert_contains  "single-VM block: ForwardAgent uses given path" "$out" "ForwardAgent /tmp/sock-alpha"
assert_absent    "single-VM single-agent: no RemoteForward"   "$out" "RemoteForward /run/tart/agent-"
# Nothing binds a fixed path here, so there is nothing to unlink.
assert_absent    "single-VM single-agent: no StreamLocalBindUnlink" "$out" "StreamLocalBindUnlink"

# Single VM, two agents: ForwardAgent = primary (first listed), additional
# agent becomes RemoteForward at /run/tart/agent-<name>.sock (tart-stacks's
# in-VM namespace).
out=$(run_sync_with_agents "vm-a alpha /tmp/sock-alpha${nl}vm-a beta /tmp/sock-beta")
assert_contains  "multi-agent: primary becomes ForwardAgent"   "$out" "ForwardAgent /tmp/sock-alpha"
assert_contains  "multi-agent: additional becomes RemoteForward at /run/tart/agent-<name>.sock" "$out" "RemoteForward /run/tart/agent-beta.sock /tmp/sock-beta"
# A fixed path survives the session that bound it, so rebinding must not be blocked by what is left behind.
assert_contains  "multi-agent: fixed socket paths are unlinked before rebinding" "$out" "StreamLocalBindUnlink yes"

# Two VMs: two distinct Host blocks in first-seen order.
out=$(run_sync_with_agents "vm-a alpha /tmp/a${nl}vm-b beta /tmp/b")
assert_contains  "two-VM: vm-a Host block" "$out" "Host tart-vm-a"
assert_contains  "two-VM: vm-b Host block" "$out" "Host tart-vm-b"
assert_contains  "two-VM: vm-a ForwardAgent" "$out" "ForwardAgent /tmp/a"
assert_contains  "two-VM: vm-b ForwardAgent" "$out" "ForwardAgent /tmp/b"

# Comment + blank line tolerance — `#` strips to end-of-line; blanks skipped.
# (Writers may use marker comments for managed-block bookkeeping.)
out=$(run_sync_with_agents "# header comment${nl}${nl}vm-a alpha /tmp/sock${nl}# trailing comment")
assert_contains  "comments and blanks tolerated" "$out" "ForwardAgent /tmp/sock"

# Malformed line (missing agent or socket) warned and skipped.
out=$(run_sync_with_agents "lonely-vm${nl}vm-b beta /tmp/b")
assert_absent    "malformed line not emitted as a Host block" "$out" "Host tart-lonely-vm"
assert_contains  "malformed line warned to stderr"            "$(<"$SYNC_ERR")" "malformed line"
assert_contains  "well-formed sibling still emitted"          "$out" "Host tart-vm-b"

# A 4th+ token would otherwise glue into the socket and emit
# `ForwardAgent <sock> <garbage>` — an OpenSSH fatal — so the line is skipped.
out=$(run_sync_with_agents "vm-a alpha /tmp/sock-a stray-token${nl}vm-b beta /tmp/b")
assert_contains  "extra-token line warned with file:line + token" "$(<"$SYNC_ERR")" "$WORK/ssh-agents:1: extra token(s) 'stray-token'"
assert_absent    "extra-token line emits no Host block"           "$out" "Host tart-vm-a"
assert_absent    "no glued socket emitted"                        "$out" "/tmp/sock-a stray-token"
assert_contains  "three-token sibling unaffected"                 "$out" "ForwardAgent /tmp/b"

# VM tokens are bare names by contract — agent forwarding is fail-closed by
# absence, so a pattern token must never widen a grant. The critical proof:
# `*` produces NO ForwardAgent anywhere (the common `Host tart-*` block at the
# top would otherwise hand the agent to every VM).
out=$(run_sync_with_agents "* alpha /tmp/sock")
assert_contains  "wildcard VM token warned and named"        "$(<"$SYNC_ERR")" "VM token '*' is not a bare name"
assert_absent    "wildcard VM token grants no agent anywhere" "$out" "ForwardAgent"
out=$(run_sync_with_agents "vm-a,vm-b alpha /tmp/sock")
assert_contains  "comma-list VM token warned and named"      "$(<"$SYNC_ERR")" "VM token 'vm-a,vm-b' is not a bare name"
assert_absent    "comma-list VM token grants no agent"       "$out" "ForwardAgent"
out=$(run_sync_with_agents "vm-a a/b /tmp/sock")
assert_contains  "agent token with '/' warned and named"     "$(<"$SYNC_ERR")" "agent token 'a/b' is not a bare name"
assert_absent    "bad agent token emits no ForwardAgent"     "$out" "ForwardAgent"
out=$(run_sync_with_agents "* alpha /tmp/sock${nl}vm-b beta /tmp/b")
assert_contains  "good sibling after a rejected wildcard still emitted" "$out" "Host tart-vm-b"
assert_contains  "good sibling keeps its ForwardAgent"                  "$out" "ForwardAgent /tmp/b"

# ── bin/tart-up mounts parser (dir_args) + bin/lib tart_pattern_matches ──────
# tart-up has no dry-run and its main flow needs a live VM, so pull the pure
# parsing functions out of the source and exercise them directly. Re-extracts
# every run, so it tracks the real source through refactors. dir_args selects
# lines via tart_pattern_matches, so source bin/lib/common.sh for the real one.
extract_fn() { # function-name file
  # Match by exact prefix and exact close-brace line — no regex, so it behaves
  # identically across awk flavors (BSD awk on macOS, mawk on the CI runner).
  awk -v fn="$1" 'index($0, fn "() {")==1{p=1} p{print} p && $0=="}"{exit}' "$2"
}
# shellcheck source=bin/lib/common.sh
. "$BIN/lib/common.sh"
{ extract_fn dir_args "$BIN/tart-up"; echo
  extract_fn netpolicy_args "$BIN/tart-up"; } > "$WORK/tart-up-fns.sh"
# shellcheck source=/dev/null
source "$WORK/tart-up-fns.sh"

MNT_ERR="$WORK/mounts.err"
mounts() { # mounts-file-content vm -> stdout of dir_args (stderr -> $MNT_ERR)
  printf '%s' "$1" > "$WORK/mounts"
  # dir_args (sourced above) reads MOUNTS_CONFIG as a global.
  # shellcheck disable=SC2034
  MOUNTS_CONFIG="$WORK/mounts"
  dir_args "$2" 2>"$MNT_ERR"
}

echo "bin/tart-up — mounts parser:"

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
assert_eq "explicit share name via name=path (avoids basename collision)" \
  "--dir=hostcfg:/Users/me/.config/myapp:ro" "$(mounts '* hostcfg=/Users/me/.config/myapp:ro' app-a)"
out=$(mounts '* relative/path' app-a)
assert_eq        "non-absolute mount path emits no --dir"   "" "$out"
assert_contains  "non-absolute mount path warned to stderr" "$(<"$MNT_ERR")" "malformed mount"

# The branch the refactor must preserve: a line with a pattern but no path is
# reported and skipped — no --dir emitted.
out=$(mounts 'app-a' app-a)
assert_eq        "no-path line emits no --dir"   "" "$out"
assert_contains  "no-path line warned to stderr" "$(<"$MNT_ERR")" "no path on line, skipping"

echo "bin/lib/common.sh — tart_pattern_matches:"
check "'*' matches any VM"              0 tart_pattern_matches '*'     anything
check "exact name matches"             0 tart_pattern_matches app-a   app-a
check "a different name does not match" 1 tart_pattern_matches app-a   app-b
check "comma-list matches a member"     0 tart_pattern_matches 'a,b,c' b
check "comma-list rejects a non-member" 1 tart_pattern_matches 'a,b,c' z

# ── bin/tart-up: netpolicy parser (netpolicy_args) ──────────
# netpolicy is VM-agnostic — one flag-list file applies uniformly to every VM.
# Tokens are whitespace-separated, # comments stripped, blank lines tolerated.
# Every token must be a tart --net-* flag: anything else fails the whole parse
# (fail-closed — a partial net-policy must never reach `tart run`), and glob
# characters in tokens stay literal.
NETP_ERR="$WORK/netpolicy.err"
netpolicy() { # netpolicy-file-content -> stdout of netpolicy_args (stderr -> $NETP_ERR)
  printf '%s' "$1" > "$WORK/netpolicy"
  # shellcheck disable=SC2034  # netpolicy_args reads this as a global
  NETPOLICY_CONFIG="$WORK/netpolicy"
  netpolicy_args 2>"$NETP_ERR"
}

echo "bin/tart-up — netpolicy parser:"
assert_eq "absent file emits no args" "" "$(NETPOLICY_CONFIG=/no/such/file netpolicy_args)"
assert_eq "empty file emits no args"  "" "$(netpolicy '')"
assert_eq "single line, whitespace-separated tokens" \
  "--net-softnet
--net-softnet-block=0.0.0.0/0
--net-softnet-allow=@host" \
  "$(netpolicy '--net-softnet --net-softnet-block=0.0.0.0/0 --net-softnet-allow=@host')"
assert_eq "multi-line tokens" \
  "--net-softnet
--net-softnet-allow=@host" \
  "$(netpolicy "--net-softnet${nl}--net-softnet-allow=@host")"
assert_eq "comment-only line skipped, trailing comment stripped" \
  "--net-softnet-allow=@host" \
  "$(netpolicy "# explainer${nl}--net-softnet-allow=@host  # @host = bridge gateway")"
assert_eq "blank lines tolerated" "--net-softnet" \
  "$(netpolicy "${nl}${nl}--net-softnet${nl}${nl}")"

# fail-closed gate: one non-`--net-*` token rejects the whole policy.
netpolicy "--net-softnet${nl}--dir=/x" >/dev/null; nrc=$?
assert_eq       "non --net-* token → rc 1"            1 "$nrc"
assert_contains "rejection names the offending token" "$(<"$NETP_ERR")" "--dir=/x"
assert_contains "rejection names the netpolicy file"  "$(<"$NETP_ERR")" "$WORK/netpolicy"

# tart's CLI accepts `--net-bridged en0`, but this contract is =-form only:
# the bare value token is refused, and the message teaches the rewrite.
netpolicy "--net-bridged en0" >/dev/null; nrc=$?
assert_eq       "space-form flag value → rc 1"            1 "$nrc"
assert_contains "space-form refusal teaches the = form"   "$(<"$NETP_ERR")" "--net-bridged=en0"

# tokenization must not pathname-expand: a glob char stays literal even when
# the cwd holds a matching file.
: > "$WORK/--net-softnet-allow=evil"
out=$(cd "$WORK" && netpolicy '--net-softnet-allow=*')
assert_eq "glob char in a token stays literal" "--net-softnet-allow=*" "$out"

# ── bin/lib/config.sh: config-path resolver ─────────────────────────────────
# Precedence: per-concern TART_<CONCERN> > TART_STACKS_CONFIG_DIR > ~/.config/tart-stacks.
# shellcheck source=bin/lib/config.sh
. "$BIN/lib/config.sh"
echo "bin/lib/config.sh — config-path resolver:"
assert_eq "default dir per concern" \
  "$HOME/.config/tart-stacks/forwards" "$(unset TART_STACKS_CONFIG_DIR TART_FORWARDS; tart_config_path forwards)"
assert_eq "TART_STACKS_CONFIG_DIR relocates a concern" \
  "/tmp/cfg/mounts" "$(unset TART_MOUNTS; TART_STACKS_CONFIG_DIR=/tmp/cfg tart_config_path mounts)"
assert_eq "per-concern TART_* wins over the dir" \
  "/custom/np" "$(TART_NETPOLICY=/custom/np TART_STACKS_CONFIG_DIR=/tmp/cfg tart_config_path netpolicy)"
assert_eq "TART_GUI wins over the config dir" \
  "/custom/gui" "$(TART_GUI=/custom/gui TART_STACKS_CONFIG_DIR=/tmp/cfg tart_config_path gui)"

# ── bin/tart-ssh-sync: config_valid + non-dry-run activation gate ───────────
# The generated file is Included by the global ssh config, so activation is
# gated on a full `ssh -G` parse. config_valid is exercised directly (same
# extract-from-source approach as the tart-up functions above), then the gate
# is driven through the real non-dry-run surface with TART_SSH_CONFIG_D
# sandboxed into $WORK.
extract_fn config_valid "$BIN/tart-ssh-sync" > "$WORK/sync-fns.sh"
# shellcheck source=/dev/null
source "$WORK/sync-fns.sh"

# The generated config's Match hook needs OpenSSH >= 10.0 (`Match
# sessiontype`); on older ssh (e.g. the ubuntu CI runner) a known-good file
# cannot pass `ssh -G` and the real script refuses to activate at all. The
# pass-path sections below self-skip there — every --dry-run test above and
# the reject paths (bad directives fail on any version) still run.
SSH_HAS_SESSIONTYPE=0
tart_ssh_has_sessiontype && SSH_HAS_SESSIONTYPE=1

echo "bin/tart-ssh-sync — config_valid:"
if [ "$SSH_HAS_SESSIONTYPE" -eq 1 ]; then
  run_sync "app-a RemoteForward 8080 127.0.0.1:8080" > "$WORK/generated.cfg"
  check "known-good generated config passes" 0 config_valid "$WORK/generated.cfg"
else
  ok "skipped: known-good pass needs OpenSSH >= 10 (Match sessiontype)"
fi
printf 'Host tart-x\n  RemoteForward\n' > "$WORK/broken.cfg"
# ssh exits 255 on parse errors; normalize so the pin isn't OpenSSH-version-shaped.
config_valid "$WORK/broken.cfg" && cv=0 || cv=1
assert_eq "bare RemoteForward directive fails validation" 1 "$cv"

echo "bin/tart-ssh-sync — non-dry-run activation:"
if [ "$SSH_HAS_SESSIONTYPE" -eq 1 ]; then
OUT_DIR="$WORK/outdir"
printf '%s\n' 'app-a RemoteForward 8080 127.0.0.1:8080' > "$WORK/forwards"
printf '%s\n' 'vm-a alpha /tmp/sock-alpha' > "$WORK/ssh-agents"
rc=0
PATH="$WORK/bin:$PATH" TART_NC_BIN='' \
TART_FORWARDS="$WORK/forwards" TART_SSH_AGENTS="$WORK/ssh-agents" \
TART_SSH_CONFIG_D="$OUT_DIR/tart-vms" \
  bash "$BIN/tart-ssh-sync" >/dev/null 2>"$SYNC_ERR" || rc=$?
assert_eq       "valid inputs: exit 0"            0 "$rc"
assert_eq       "output file written"             yes "$([ -f "$OUT_DIR/tart-vms" ] && echo yes || echo no)"
assert_contains "output mode is 600"              "$(ls -l "$OUT_DIR/tart-vms")" "-rw-------"
assert_contains "output carries the wildcard block"     "$(<"$OUT_DIR/tart-vms")" "Host tart-*"
assert_contains "output carries the per-VM agent block" "$(<"$OUT_DIR/tart-vms")" "ForwardAgent /tmp/sock-alpha"
assert_eq       "no rejected candidate on success" no "$([ -f "$OUT_DIR/tart-vms.rejected" ] && echo yes || echo no)"

# Rejection through the public surface: junk RemoteForward args pass the
# parser's has-arguments gate but fail ssh's own parse — the emission-bug
# class the net exists to stop. The prior good live file must survive.
printf '%s\n' 'app-a RemoteForward junk junk' > "$WORK/forwards"
rc=0
PATH="$WORK/bin:$PATH" TART_NC_BIN='' \
TART_FORWARDS="$WORK/forwards" TART_SSH_AGENTS="$WORK/ssh-agents" \
TART_SSH_CONFIG_D="$OUT_DIR/tart-vms" \
  bash "$BIN/tart-ssh-sync" >/dev/null 2>"$SYNC_ERR" || rc=$?
assert_eq       "invalid emission: nonzero exit"  1 "$rc"
assert_contains "error names the rejected path"   "$(<"$SYNC_ERR")" "$OUT_DIR/tart-vms.rejected"
assert_eq       "rejected candidate preserved"    yes "$([ -f "$OUT_DIR/tart-vms.rejected" ] && echo yes || echo no)"
assert_contains "live file untouched (prior content intact)" "$(<"$OUT_DIR/tart-vms")" "RemoteForward 8080 127.0.0.1:8080"
assert_absent   "live file free of the junk forward"         "$(<"$OUT_DIR/tart-vms")" "junk"

# A later healthy sync supersedes the failure it documented: .rejected is gone.
printf '%s\n' 'app-a RemoteForward 8080 127.0.0.1:8080' > "$WORK/forwards"
rc=0
PATH="$WORK/bin:$PATH" TART_NC_BIN='' \
TART_FORWARDS="$WORK/forwards" TART_SSH_AGENTS="$WORK/ssh-agents" \
TART_SSH_CONFIG_D="$OUT_DIR/tart-vms" \
  bash "$BIN/tart-ssh-sync" >/dev/null 2>"$SYNC_ERR" || rc=$?
assert_eq "recovery sync: exit 0" 0 "$rc"
assert_eq "recovery sync clears the stale rejected candidate" no "$([ -f "$OUT_DIR/tart-vms.rejected" ] && echo yes || echo no)"
else
  ok "skipped: activation pass/reject/recovery need OpenSSH >= 10 (Match sessiontype)"
fi

echo
echo "  $pass passed, $fail failed"
[ "$fail" -eq 0 ]
