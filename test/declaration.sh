#!/usr/bin/env bash
# The declaration contract: every stack's `tools` file is the canonical tool
# declaration, and this test holds every derived surface to it — the
# installers' smoke_gate calls (set equality, per platform, both directions),
# membership_gate's token list and the PECL loop (php), and files/mise.toml's
# [tools] keys plus the node.corepack setting (both directions). script/smoke
# executes the same rows at runtime, so what this file proves statically is
# exactly what the build gates and the runtime probes agree on.
#
# The checker is one function (declaration_check) run over the real stacks,
# the scaffold (materialized with __STACK__ substituted, same technique as
# make lint), and a set of synthetic negative fixtures — every refusal case
# has a must-pass control beside it, per the suite's standing rule. The gate
# lexer never evaluates shell: it captures column-0 calls plus their
# backslash continuations and tokenizes quote-aware in awk. Column-0 is
# syntactic parity, not reachability — bash ignores indentation — and the
# real execution evidence is the build log's gate-label lines, checked at
# rebuild time, not here. Real-file lexer expectations below double as
# captured fixtures: they pin the lexer's exact output against the shipped
# installers, so a formatting change breaks the lexer test rather than
# silently emptying the checks.
#
# Bash 3.2 floor (macOS /bin/bash): no declare -A, no mapfile.
#
# shellcheck disable=SC2016  # the file's whole business is matching and
# writing LITERAL shell text — '$(php -m)' in fixtures and lexer expectations
# must never expand.
set -uo pipefail

TEST_DIR=$(cd -P "$(dirname "$0")" >/dev/null 2>&1 && pwd)
REPO=$(cd -P "$TEST_DIR/.." >/dev/null 2>&1 && pwd)

pass=0 fail=0
ok()  { pass=$((pass + 1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  FAIL %s\n         %s\n' "$1" "${2:-}"; }
assert_contains() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "want » $3 « in: $2" ;; esac; }

WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT

# ── grammar ─────────────────────────────────────────────────────────────────
# Command words (proof argv[0], name, binary): first char alphanumeric or
# underscore — an option or `.` can never be a command — and no =/:/ / so an
# assignment or path can never be one either. Argument words are wider.
CMD_WORD='^[A-Za-z0-9_][A-Za-z0-9_.+-]*$'
ARG_WORD='^[A-Za-z0-9_.+=/:@-]+$'
EXT_TOKEN='^[a-z0-9_][a-z0-9_ .-]*$'

# name -> binary aliases: the irreducible convention facts, in one reviewed
# place. Everything else requires name == binary.
alias_binary() { # <name> — prints the expected binary
  case "$1" in
    maven)  echo mvn ;;
    kotlin) echo kotlinc ;;
    *)      echo "$1" ;;
  esac
}

# ── tools-file parser ───────────────────────────────────────────────────────
# Emits one line per row: "tool<TAB>name<TAB>binary<TAB>managed<TAB>proof" or
# "ext<TAB>token<TAB>source", plus "ERR<TAB>msg" per violation. Purpose is
# validated (non-empty) but not re-emitted — nothing downstream consumes it.
parse_tools() { # <tools-file>
  awk -F'|' '
    /^[ \t]*#/ { next }
    /^[ \t]*$/ { next }
    # A tab anywhere in a row corrupts this parser own tab-separated output
    # and the field alignment of every downstream reader — reject before
    # emitting anything.
    /\t/ { print "ERR\ttab character in row: " $0; next }
    $1 == "tool" {
      if (NF != 6) { print "ERR\ttool row needs 6 fields, has " NF ": " $0; next }
      for (i = 2; i <= 6; i++) if ($i == "") { print "ERR\tempty field " i " in tool row: " $0; next }
      print "tool\t" $2 "\t" $3 "\t" $4 "\t" $5
      next
    }
    $1 == "ext" {
      if (NF != 3) { print "ERR\text row needs 3 fields, has " NF ": " $0; next }
      if ($2 == "" || $3 == "") { print "ERR\tempty field in ext row: " $0; next }
      print "ext\t" $2 "\t" $3
      next
    }
    { print "ERR\tunknown row type: " $0 }
  ' "$1"
}

# ── mise.toml parser ────────────────────────────────────────────────────────
# The closed file contract: root content is comments/blanks only; allowed
# section headers are [tools], [settings], [tool_alias]; in-region lines are
# single key = value assignments with the key optionally quoted and the value
# quoted or matching a bare-word grammar. Emits "SECTION<TAB>key<TAB>quoted"
# lines and "ERR<TAB>msg" per violation. Never evaluates anything.
parse_mise() { # <mise.toml>
  awk '
    BEGIN { sect = "ROOT" }
    /^[ \t]*#/ { next }
    /^[ \t]*$/ { next }
    /^\[/ {
      if ($0 == "[tools]" || $0 == "[settings]" || $0 == "[tool_alias]") sect = $0
      else print "ERR\tunsupported section header: " $0
      next
    }
    {
      line = $0
      quoted = "bare"
      if (line ~ /^"[^"]+"[ \t]*=[ \t]*/) {
        quoted = "quoted"
        key = line; sub(/^"/, "", key); sub(/".*$/, "", key)
        val = line; sub(/^"[^"]+"[ \t]*=[ \t]*/, "", val)
      } else if (line ~ /^[A-Za-z0-9._-]+[ \t]*=[ \t]*/) {
        key = line; sub(/[ \t]*=.*$/, "", key)
        val = line; sub(/^[A-Za-z0-9._-]+[ \t]*=[ \t]*/, "", val)
      } else {
        if (sect == "ROOT") print "ERR\troot-level content (only comments and blanks may sit outside a section): " $0
        else print "ERR\tunparseable line in " sect ": " $0
        next
      }
      if (sect == "ROOT") { print "ERR\troot-level assignment (every assignment belongs to a section): " $0; next }
      sub(/[ \t]*$/, "", val)
      if (val ~ /^"[^"]*"$/) { sub(/^"/, "", val); sub(/"$/, "", val) }
      else if (val ~ /^[A-Za-z0-9._-]+$/) ;
      else {
        print "ERR\tunsupported value in " sect ": " $0
        next
      }
      print sect "\t" key "\t" quoted "\t" val
    }
  ' "$1"
}

# ── gate lexer ──────────────────────────────────────────────────────────────
# Captures each column-0 smoke_gate/membership_gate call plus its backslash
# continuations, joined to one line. Heredoc bodies are skipped — a gate call
# quoted inside `cat <<EOF … EOF` is text, not a statement, and counting it
# would let the real gate be deleted while equality stays green. A call whose
# continuation runs into end-of-file is reported, not silently dropped.
# Tokenizes quote-aware (single and double, no escapes — none occur in the
# shapes this repo writes), never evaluating.
gate_calls() { # <installer> <gate-name> — one joined call text per line; ERR lines on lexer trouble
  awk -v gate="$2" '
    inheredoc {
      if ($0 == hd_term) inheredoc = 0
      next
    }
    incall {
      line = $0
      cont = (line ~ /\\$/)
      sub(/[ \t]*\\$/, "", line)
      sub(/^[ \t]*/, "", line)
      text = text " " line
      if (!cont) { print text; text = ""; incall = 0 }
      next
    }
    # Heredoc start on any line: <<EOF, <<-EOF, <<\x27EOF\x27, <<"EOF". The
    # terminator is matched as the whole line, which is how every heredoc in
    # this repo is written.
    match($0, /<<-?[\x27"]?[A-Za-z_][A-Za-z0-9_]*[\x27"]?/) {
      hd_term = substr($0, RSTART, RLENGTH)
      sub(/^<<-?/, "", hd_term); gsub(/[\x27"]/, "", hd_term)
      inheredoc = 1
      next
    }
    index($0, gate " ") == 1 {
      line = $0
      cont = (line ~ /\\$/)
      sub(/[ \t]*\\$/, "", line)
      if (cont) { text = line; incall = 1 } else print line
    }
    END {
      if (incall) print "ERR\t" gate " call has an unterminated backslash continuation at end of file"
      if (inheredoc) print "ERR\tunterminated heredoc (terminator " hd_term " never found)"
    }
  ' "$1"
}

lex_tokens() { # stdin: one call text — one token per line, quotes stripped
  awk '
    {
      s = $0; n = length(s); tok = ""; has = 0
      for (i = 1; i <= n; i++) {
        c = substr(s, i, 1)
        if (c == "\x27") {
          has = 1; i++
          while (i <= n && substr(s, i, 1) != "\x27") { tok = tok substr(s, i, 1); i++ }
        } else if (c == "\"") {
          has = 1; i++
          while (i <= n && substr(s, i, 1) != "\"") { tok = tok substr(s, i, 1); i++ }
        } else if (c == " " || c == "\t") {
          if (tok != "" || has) { print tok; tok = ""; has = 0 }
        } else { tok = tok c; has = 1 }
      }
      if (tok != "" || has) print tok
    }
  '
}

# Group words are joined with \x1f (unit separator), never a space: a quoted
# single token "uv --version" must NOT compare equal to the two-word proof it
# spells — the build would exec a program literally named 'uv --version'.
# Declared proofs are encoded the same way before comparison.
smoke_gate_groups() { # <installer> — one \x1f-joined group per line; ERR lines pass through
  local call
  while IFS= read -r call; do
    case "$call" in "ERR	"*) printf '%s\n' "$call"; continue ;; esac
    printf '%s\n' "$call" | lex_tokens | awk '
      NR == 1 { next }        # the literal smoke_gate word
      NR == 2 { next }        # the label
      $0 == "--" { if (grp != "") print grp; grp = ""; next }
      { grp = (grp == "" ? $0 : grp "\037" $0) }
      END { if (grp != "") print grp }
    '
  done < <(gate_calls "$1" smoke_gate)
}

encode_proof() { # stdin: space-separated proofs — US(\037)-joined, for comparison
  tr ' ' '\037'
}

membership_tokens() { # <installer> — one token per line; ERR lines on misuse
  local call
  while IFS= read -r call; do
    case "$call" in "ERR	"*) printf '%s\n' "$call"; continue ;; esac
    printf '%s\n' "$call" | lex_tokens | awk '
      NR == 1 { next }        # the literal membership_gate word
      NR == 2 { next }        # the label
      NR == 3 {
        listing = 1
        if ($0 != "$(php -m)") print "ERR\tmembership listing must be exactly \"$(php -m)\", got: " $0
        next
      }
      $0 == "" { print "ERR\tempty membership token (a quoted \"\" matches the blank separator in php -m output)"; next }
      { print }
      END { if (NR >= 1 && !listing) print "ERR\tmembership_gate call has no listing argument (the real build would fail under set -u)" }
    '
  done < <(gate_calls "$1" membership_gate)
}

pecl_loop_tokens() { # <installer> — one extension per line
  sed -n 's/^for ext in \(.*\); do$/\1/p' "$1" | tr ' ' '\n' | sed '/^$/d'
}

# ── set comparison ──────────────────────────────────────────────────────────
set_diff() { # <list-a> <list-b> — lines in a but not b (inputs newline lists)
  comm -23 <(printf '%s' "$1" | sed '/^$/d' | sort) <(printf '%s' "$2" | sed '/^$/d' | sort)
}

# ── the checker ─────────────────────────────────────────────────────────────
# Runs every check for one stack directory; prints findings, returns nonzero
# if any. Callers decide whether findings are a failure (real stacks) or the
# expected outcome (negative fixtures).
declaration_check() { # <stack-dir> <label>
  local dir="$1" label="$2" findings=0
  flag() { findings=$((findings + 1)); printf '%s: %s\n' "$label" "$1"; }

  local tools_file="$dir/tools"
  if [ ! -f "$tools_file" ]; then
    flag "no tools declaration file"
    return 1
  fi

  local rows
  rows=$(parse_tools "$tools_file")
  local errs
  errs=$(printf '%s\n' "$rows" | awk -F'\t' '$1 == "ERR" { print $2 }')
  [ -n "$errs" ] && while IFS= read -r e; do flag "tools parse: $e"; done <<< "$errs"

  local names="" binaries="" proofs="" ext_tokens="" pecl_exts="" mise_keys="" has_node=0 corepack_rows=""
  local t name binary managed proof
  while IFS=$'\t' read -r t name binary managed proof; do
    case "$t" in
      tool)
        printf '%s' "$name"   | grep -qE "$CMD_WORD" || flag "name violates the command-word grammar: '$name'"
        printf '%s' "$binary" | grep -qE "$CMD_WORD" || flag "binary violates the command-word grammar: '$binary'"
        [ "$binary" = "$(alias_binary "$name")" ] || flag "binary '$binary' does not match name '$name' (alias table says '$(alias_binary "$name")')"
        # proof: raw-field whitespace discipline, then per-word grammar. The
        # tokenization is tr-based, never an unquoted expansion — `for w in
        # $proof` would glob a `*` against the repo's own files and could
        # satisfy the word grammar with expanded filenames.
        case "$proof" in
          ''|*'  '*|*'	'*|' '*|*' ') flag "proof has empty/tab/repeated/edge whitespace: '$proof'" ;;
        esac
        local w first=1 words_ok=1 argv0=""
        while IFS= read -r w; do
          [ -z "$w" ] && continue
          if [ "$first" = 1 ]; then
            argv0="$w"; first=0
            printf '%s' "$w" | grep -qE "$CMD_WORD" || { flag "proof argv[0] violates the command-word grammar: '$w'"; words_ok=0; }
          else
            [ "$w" = "--" ] && { flag "standalone -- is reserved (smoke_gate group delimiter): '$proof'"; words_ok=0; }
            printf '%s' "$w" | grep -qE "$ARG_WORD" || { flag "proof word violates the argument grammar: '$w'"; words_ok=0; }
          fi
        done < <(printf '%s\n' "$proof" | tr ' ' '\n')
        if [ "$words_ok" = 1 ]; then
          if [ "$argv0" = "command" ]; then
            case "$name" in
              pnpm|yarn) [ "$proof" = "command -v $binary" ] || flag "the blessed existence form is exactly 'command -v $binary', got: '$proof'" ;;
              *) flag "command -v proofs are legal only on the pnpm/yarn rows, not '$name'" ;;
            esac
          else
            [ "$argv0" = "$binary" ] || flag "proof argv[0] '$argv0' is not the row's binary '$binary'"
          fi
        fi
        # The corepack obligations key off the canonical NAME, before any
        # dispatch on managed-by — a node row wearing managed-by=installer
        # must not slip past the trio/setting rule.
        if [ "$name" = "node" ]; then
          has_node=1
          [ "$managed" = "mise:node" ] || flag "the node row must be managed-by mise:node exactly (alternate Node backends and non-mise Node are forbidden)"
        fi
        case "$managed" in
          mise:*)
            local key="${managed#mise:}"
            case "$key" in
              *:*) ;;  # backend-prefixed: existence checked against mise.toml below
              *) [ "$key" = "$name" ] || flag "plain mise key '$key' must equal the row name '$name'" ;;
            esac
            mise_keys="$mise_keys$key
"
            ;;
          node-corepack)
            case "$name" in
              corepack|pnpm|yarn) corepack_rows="$corepack_rows$name
" ;;
              *) flag "node-corepack rows have fixed identities corepack/pnpm/yarn, not '$name'" ;;
            esac
            ;;
          installer) ;;
          *) flag "unknown managed-by '$managed' on '$name'" ;;
        esac
        names="$names$name
"
        binaries="$binaries$binary
"
        proofs="$proofs$proof
"
        ;;
      ext)
        # fields shift for ext rows: $2 token, $3 source
        local token="$name" source="$binary"
        printf '%s' "$token" | grep -qE "$EXT_TOKEN" || flag "ext token violates the token grammar: '$token'"
        case "$token" in *'  '*|*' ') flag "ext token has repeated/trailing spaces: '$token'" ;; esac
        case "$source" in
          pecl) pecl_exts="$pecl_exts$token
" ;;
          bundled) ;;
          *) flag "ext source must be pecl or bundled, got '$source' on '$token'" ;;
        esac
        ext_tokens="$ext_tokens$token
"
        ;;
    esac
  done < <(printf '%s\n' "$rows" | awk -F'\t' '$1 != "ERR"')

  local dups
  dups=$(printf '%s' "$names" | sed '/^$/d' | sort | uniq -d)
  [ -n "$dups" ] && flag "duplicate tool names: $(echo "$dups" | tr '\n' ' ')"
  dups=$(printf '%s' "$binaries" | sed '/^$/d' | sort | uniq -d)
  [ -n "$dups" ] && flag "duplicate binaries: $(echo "$dups" | tr '\n' ' ')"
  # ext uniqueness is case-folded: membership matching is case-insensitive, so
  # two tokens differing only by case would be one gate check wearing two rows.
  dups=$(printf '%s' "$ext_tokens" | sed '/^$/d' | tr '[:upper:]' '[:lower:]' | sort | uniq -d)
  [ -n "$dups" ] && flag "duplicate ext tokens (case-folded): $(echo "$dups" | tr '\n' ' ')"

  # ── mise.toml ─────────────────────────────────────────────────────────────
  local mise_file="$dir/files/mise.toml"
  local toml_tools="" setting_ok=0 setting_present=0
  if [ ! -f "$mise_file" ]; then
    flag "no files/mise.toml"
  else
    local parsed
    parsed=$(parse_mise "$mise_file")
    errs=$(printf '%s\n' "$parsed" | awk -F'\t' '$1 == "ERR" { print $2 }')
    [ -n "$errs" ] && while IFS= read -r e; do flag "mise.toml: $e"; done <<< "$errs"
    toml_tools=$(printf '%s\n' "$parsed" | awk -F'\t' '$1 == "[tools]" { print $2 }')
    # Duplicate decoded keys are a violation in EVERY section — the closed
    # file contract, not just the [tools] slice of it.
    local sect
    for sect in '[tools]' '[settings]' '[tool_alias]'; do
      dups=$(printf '%s\n' "$parsed" | awk -F'\t' -v s="$sect" '$1 == s { print $2 }' | sort | uniq -d)
      [ -n "$dups" ] && flag "duplicate $sect keys: $(echo "$dups" | tr '\n' ' ')"
    done
    # the setting counts only as the unquoted dotted spelling — a quoted
    # "node.corepack" is a different TOML key (a literal, not a path) — and
    # only WITH the value true, read from the parser's own decoded value for
    # the [settings] row, never a file-global grep (a node.corepack line in
    # another section must not stand in for it).
    if printf '%s\n' "$parsed" | awk -F'\t' '$1 == "[settings]" && $2 == "node.corepack" && $3 == "quoted" { found = 1 } END { exit !found }'; then
      flag "mise.toml: [settings] uses the quoted \"node.corepack\" spelling — TOML reads that as a literal key, not the node.corepack path"
    fi
    if printf '%s\n' "$parsed" | awk -F'\t' '$1 == "[settings]" && $2 == "node.corepack" && $3 == "bare" { found = 1 } END { exit !found }'; then
      setting_present=1
      printf '%s\n' "$parsed" | awk -F'\t' '$1 == "[settings]" && $2 == "node.corepack" && $3 == "bare" && $4 == "true" { found = 1 } END { exit !found }' && setting_ok=1
    fi
    if printf '%s\n' "$parsed" | awk -F'\t' '$1 == "[tool_alias]" && $2 == "node" { found = 1 } END { exit !found }'; then
      flag "mise.toml: [tool_alias] redirects node to another backend — forbidden, it would silently change what mise:node installs"
    fi
  fi

  local extra
  extra=$(set_diff "$mise_keys" "$toml_tools")
  [ -n "$extra" ] && flag "declared mise keys absent from [tools]: $(echo "$extra" | tr '\n' ' ')"
  extra=$(set_diff "$toml_tools" "$mise_keys")
  [ -n "$extra" ] && flag "[tools] keys with no declaration row (installed-but-undeclared): $(echo "$extra" | tr '\n' ' ')"

  # ── corepack structural rule ──────────────────────────────────────────────
  # A stack must have zero tool rows never: an ext-only declaration would
  # leave script/smoke refusing at runtime while every static equality here
  # holds vacuously — the static check refuses first.
  local n_tools
  n_tools=$(printf '%s' "$names" | sed '/^$/d' | wc -l | tr -d ' ')
  [ "$n_tools" = 0 ] && flag "no tool rows — an ext-only declaration probes nothing at runtime and gates nothing at build"
  local n_corepack
  n_corepack=$(printf '%s' "$corepack_rows" | sed '/^$/d' | sort -u | wc -l | tr -d ' ')
  if [ "$has_node" = 1 ]; then
    [ "$n_corepack" = 3 ] || flag "a stack declaring mise:node must declare all three node-corepack rows (corepack, pnpm, yarn) — mise_runtime_setup ships their shims with every Node stack"
    [ "$setting_ok" = 1 ] || flag "a stack declaring mise:node must set node.corepack = true in [settings] (project-pinned Nodes <= 24 get shims from it)"
  else
    [ "$n_corepack" = 0 ] || flag "node-corepack rows in a stack that does not declare mise:node"
    [ "$setting_present" = 0 ] || flag "a node.corepack setting (any value) in a stack that does not declare mise:node"
  fi

  # ── build gates, per platform ─────────────────────────────────────────────
  local platform inst groups
  for platform in linux darwin; do
    inst="$dir/scripts/$platform/mise-install.sh"
    if [ ! -f "$inst" ]; then
      flag "no $platform installer at scripts/$platform/mise-install.sh"
      continue
    fi
    groups=$(smoke_gate_groups "$inst")
    local gate_errs
    gate_errs=$(printf '%s\n' "$groups" | awk -F'\t' '$1 == "ERR" { print $2 }')
    [ -n "$gate_errs" ] && while IFS= read -r e; do flag "$platform: $e"; done <<< "$gate_errs"
    groups=$(printf '%s\n' "$groups" | awk -F'\t' '$1 != "ERR"')
    # Proofs are encoded to \x1f word joins before comparison so a quoted
    # single token spelling a two-word proof cannot compare equal.
    local enc_proofs
    enc_proofs=$(printf '%s' "$proofs" | encode_proof)
    extra=$(set_diff "$enc_proofs" "$groups")
    [ -n "$extra" ] && flag "$platform: declared proofs missing from smoke_gate: $(echo "$extra" | tr '\034\035\036\037' ' ' | tr '\n' ';')"
    extra=$(set_diff "$groups" "$enc_proofs")
    [ -n "$extra" ] && flag "$platform: smoke_gate groups with no declaration row: $(echo "$extra" | tr '\034\035\036\037' ' ' | tr '\n' ';')"

    local memb memb_errs
    memb=$(membership_tokens "$inst")
    memb_errs=$(printf '%s\n' "$memb" | awk -F'\t' '$1 == "ERR" { print $2 }')
    [ -n "$memb_errs" ] && while IFS= read -r e; do flag "$platform: $e"; done <<< "$memb_errs"
    memb=$(printf '%s\n' "$memb" | awk -F'\t' '$1 != "ERR"' | sed '/^$/d')
    if [ -n "$ext_tokens$(printf '%s' "$memb")" ]; then
      extra=$(set_diff "$ext_tokens" "$memb")
      [ -n "$extra" ] && flag "$platform: ext rows missing from membership_gate: $(echo "$extra" | tr '\n' ';')"
      extra=$(set_diff "$(printf '%s' "$memb")
" "$ext_tokens")
      [ -n "$extra" ] && flag "$platform: membership_gate tokens with no ext row: $(echo "$extra" | tr '\n' ';')"
    fi

    local loop
    loop=$(pecl_loop_tokens "$inst")
    if [ -n "$pecl_exts$loop" ]; then
      extra=$(set_diff "$pecl_exts" "$loop")
      [ -n "$extra" ] && flag "$platform: pecl ext rows missing from the PECL install loop: $(echo "$extra" | tr '\n' ' ')"
      extra=$(set_diff "$loop
" "$pecl_exts")
      [ -n "$extra" ] && flag "$platform: PECL loop installs extensions with no pecl ext row: $(echo "$extra" | tr '\n' ' ')"
    fi
  done

  [ "$findings" -eq 0 ]
}

# ── the real stacks + the scaffold ──────────────────────────────────────────
echo "declaration — real stacks and the scaffold hold the contract:"

# Materialize the scaffold exactly the way `make scaffold` does, so its
# templates are checked as the stack they would stamp.
SCAF="$WORK/scaffold-demo"
mkdir -p "$SCAF"
(cd "$REPO/templates/stack" && find . -type f | while IFS= read -r f; do
  dest="$SCAF/${f#./}"; dest="${dest%.tmpl}"
  mkdir -p "$(dirname "$dest")"
  sed 's/__STACK__/demo/g' "$REPO/templates/stack/${f#./}" > "$dest"
done)

shopt -s nullglob
checked=0
for dir in "$REPO"/stacks/*/ "$SCAF/"; do
  [ -d "$dir" ] || continue
  name=$(basename "$dir")
  [ "$dir" = "$SCAF/" ] && name="scaffold(demo)"
  checked=$((checked + 1))
  if findings=$(declaration_check "${dir%/}" "$name"); then
    ok "$name holds the declaration contract"
  else
    bad "$name holds the declaration contract" "$findings"
  fi
done
if [ "$checked" -ge 3 ]; then
  ok "walked $checked stacks (php, jvm, scaffold at minimum)"
else
  bad "walked $checked stacks (php, jvm, scaffold at minimum)" "the walk found fewer stacks than exist — discovery is broken"
fi

# ── lexer output pinned against the shipped installers (captured fixtures) ──
# Equality alone would stay green if the lexer and the declaration were wrong
# together; these pin the lexer's exact output against hand-verified shapes —
# php linux carries the continued runtimes call, the single-line composer
# call, the quoted multiword membership token, and the "$(php -m)" listing.
echo
echo "declaration — gate lexer against the shipped installers:"
PHP_INST="$REPO/stacks/php/scripts/linux/mise-install.sh"
got=$(smoke_gate_groups "$PHP_INST" | sort)
want=$(printf '%s\n' "command -v pnpm" "command -v yarn" "composer --version" "corepack --version" "node --version" "php --version" | encode_proof | sort)
if [ "$got" = "$want" ]; then
  ok "php linux smoke_gate groups lex exactly (argv-boundary encoded)"
else
  bad "php linux smoke_gate groups lex exactly (argv-boundary encoded)" "want » $(echo "$want" | tr '\037' '·' | tr '\n' ';') « got » $(echo "$got" | tr '\037' '·' | tr '\n' ';') «"
fi
got=$(membership_tokens "$PHP_INST" | grep -c 'zend opcache' || true)
if [ "$got" = "1" ]; then
  ok "php linux membership lexes 'zend opcache' as one token"
else
  bad "php linux membership lexes 'zend opcache' as one token" "matched $got times"
fi
got=$(smoke_gate_groups "$REPO/stacks/jvm/scripts/linux/mise-install.sh" | wc -l | tr -d ' ')
if [ "$got" = "11" ]; then
  ok "jvm linux smoke_gate lexes 11 groups from the continued call"
else
  bad "jvm linux smoke_gate lexes 11 groups from the continued call" "got $got"
fi

# ── script/smoke wiring ─────────────────────────────────────────────────────
# Anchored to the executable lines: comments in script/smoke also name the
# tools file, so an unanchored match would stay green with the read deleted.
echo
echo "declaration — script/smoke consumes the declaration:"
if grep -qE '^TOOLS_FILE="\$REPO/stacks/\$STACK/tools"$' "$REPO/script/smoke"; then
  ok "script/smoke reads stacks/<stack>/tools"
else
  bad "script/smoke reads stacks/<stack>/tools" "no executable TOOLS_FILE line found"
fi
if grep -qE '^probes=\$\(awk -F' "$REPO/script/smoke"; then
  ok "script/smoke derives probes from the tool rows"
else
  bad "script/smoke derives probes from the tool rows" "no executable probes= line found"
fi

# ── negative fixtures — every refusal has a must-pass control ───────────────
# mk_stack builds a MINIMAL VALID stack (uv-only: no node, so no corepack
# obligations); mk_node_stack builds the valid node-bearing shape. Each
# negative fixture is one of these plus exactly one defect, and asserts both
# the failure and its wording.
echo
echo "declaration — negative fixtures (each beside its must-pass control):"

mk_stack() { # <dir>
  mkdir -p "$1/files" "$1/scripts/linux" "$1/scripts/darwin"
  printf 'tool|uv|uv|mise:uv|uv --version|python project manager\n' > "$1/tools"
  printf '[tools]\nuv = "latest"\n' > "$1/files/mise.toml"
  local p
  for p in linux darwin; do
    printf 'smoke_gate "runtimes" -- uv --version\n' > "$1/scripts/$p/mise-install.sh"
  done
}
mk_node_stack() { # <dir>
  mkdir -p "$1/files" "$1/scripts/linux" "$1/scripts/darwin"
  cat > "$1/tools" <<'EOF'
tool|node|node|mise:node|node --version|js runtime
tool|corepack|corepack|node-corepack|corepack --version|shim dispatcher
tool|pnpm|pnpm|node-corepack|command -v pnpm|corepack shim
tool|yarn|yarn|node-corepack|command -v yarn|corepack shim
EOF
  printf '[tools]\nnode = "lts"\n\n[settings]\nnode.corepack = true\n' > "$1/files/mise.toml"
  local p
  for p in linux darwin; do
    printf 'smoke_gate "runtimes" -- node --version -- corepack --version -- command -v pnpm -- command -v yarn\n' > "$1/scripts/$p/mise-install.sh"
  done
}

run_fixture() { # <label> <dir> — sets $frc and $fout
  frc=0
  fout=$(declaration_check "$2" fixture) || frc=$?
}

mk_stack "$WORK/ok-min"
run_fixture minimal "$WORK/ok-min"
if [ "$frc" -eq 0 ]; then ok "minimal valid stack → passes (must-pass control)"; else bad "minimal valid stack → passes (must-pass control)" "$fout"; fi

mk_node_stack "$WORK/ok-node"
run_fixture node "$WORK/ok-node"
if [ "$frc" -eq 0 ]; then ok "node-bearing valid stack → passes (must-pass control)"; else bad "node-bearing valid stack → passes (must-pass control)" "$fout"; fi

fixture_red() { # <label> <expected-wording> <mutator...>
  local label="$1" want="$2"; shift 2
  local d="$WORK/red-$pass-$fail"; rm -rf "$d"
  "$@" "$d"
  run_fixture "$label" "$d"
  if [ "$frc" -ne 0 ]; then ok "$label → red"; else bad "$label → red" "fixture passed but must fail"; fi
  assert_contains "$label names the defect" "$fout" "$want"
}

mut_missing_tools()   { mk_stack "$1"; rm "$1/tools"; }
fixture_red "missing tools file" "no tools declaration file" mut_missing_tools

mut_bad_proof()       { mk_stack "$1"; printf 'tool|jq|jq|installer|jq --version; rm -rf /|json tool\n' >> "$1/tools"; }
fixture_red "shell syntax in a proof" "argument grammar" mut_bad_proof

mut_assign_proof()    { mk_stack "$1"; printf 'tool|foo|FOO=bar|installer|FOO=bar|fake\n' >> "$1/tools"; }
fixture_red "assignment as binary/proof" "command-word grammar" mut_assign_proof

mut_missing_group()   { mk_node_stack "$1"; printf 'smoke_gate "runtimes" -- node --version -- corepack --version -- command -v pnpm\n' > "$1/scripts/darwin/mise-install.sh"; }
fixture_red "gate group deleted on one platform only" "declared proofs missing from smoke_gate" mut_missing_group

mut_orphan_group()    { mk_stack "$1"; printf 'smoke_gate "extra" -- jq --version\n' >> "$1/scripts/linux/mise-install.sh"; }
fixture_red "gate group with no declaration row" "smoke_gate groups with no declaration row" mut_orphan_group

mut_extra_mise_key()  { mk_stack "$1"; printf 'ruby = "latest"\n' >> "$1/files/mise.toml"; }
fixture_red "mise.toml key with no row" "installed-but-undeclared" mut_extra_mise_key

mut_ghost_mise_row()  { mk_stack "$1"; printf 'tool|ruby|ruby|mise:ruby|ruby --version|ghost\n' >> "$1/tools"; printf 'smoke_gate "g" -- ruby --version\n' >> "$1/scripts/linux/mise-install.sh"; printf 'smoke_gate "g" -- ruby --version\n' >> "$1/scripts/darwin/mise-install.sh"; }
fixture_red "declared mise tool absent from mise.toml" "absent from [tools]" mut_ghost_mise_row

mut_corepack_no_node(){ mk_stack "$1"; printf 'tool|corepack|corepack|node-corepack|corepack --version|shims\n' >> "$1/tools"; printf 'smoke_gate "c" -- corepack --version\n' >> "$1/scripts/linux/mise-install.sh"; printf 'smoke_gate "c" -- corepack --version\n' >> "$1/scripts/darwin/mise-install.sh"; }
fixture_red "corepack rows without mise:node" "does not declare mise:node" mut_corepack_no_node

mut_node_no_corepack(){ mk_node_stack "$1"; grep -v 'node-corepack' "$1/tools" > "$1/tools.t" && mv "$1/tools.t" "$1/tools"
  local p; for p in linux darwin; do printf 'smoke_gate "runtimes" -- node --version\n' > "$1/scripts/$p/mise-install.sh"; done; }
fixture_red "mise:node without the corepack trio" "must declare all three node-corepack rows" mut_node_no_corepack

mut_node_no_setting() { mk_node_stack "$1"; printf '[tools]\nnode = "lts"\n' > "$1/files/mise.toml"; }
fixture_red "mise:node without node.corepack = true" "must set node.corepack = true" mut_node_no_setting

mut_quoted_setting()  { mk_node_stack "$1"; printf '[tools]\nnode = "lts"\n\n[settings]\n"node.corepack" = true\n' > "$1/files/mise.toml"; }
fixture_red "quoted \"node.corepack\" spelling" "literal key" mut_quoted_setting

mut_node_alias()      { mk_node_stack "$1"; printf '\n[tool_alias]\nnode = "vfox:example/other-node"\n' >> "$1/files/mise.toml"; }
fixture_red "[tool_alias] redirecting node" "redirects node" mut_node_alias

mut_root_assign()     { mk_stack "$1"; printf 'tools.uv = "latest"\n[tools]\nuv = "latest"\n' > "$1/files/mise.toml"; }
fixture_red "root-level tools.uv assignment" "root-level" mut_root_assign

mut_bad_section()     { mk_stack "$1"; printf '[tools]\nuv = "latest"\n[tools.extra]\nx = "y"\n' > "$1/files/mise.toml"; }
fixture_red "structured [tools.…] section" "unsupported section header" mut_bad_section

mut_swap_binary()     { mk_stack "$1"; printf 'tool|maven|gradle|mise:maven|gradle --version|swapped\n' >> "$1/tools"; printf 'maven = "latest"\n' >> "$1/files/mise.toml"; printf 'smoke_gate "m" -- gradle --version\n' >> "$1/scripts/linux/mise-install.sh"; printf 'smoke_gate "m" -- gradle --version\n' >> "$1/scripts/darwin/mise-install.sh"; }
fixture_red "binary swapped against the alias table" "does not match name" mut_swap_binary

mut_command_v_abuse() { mk_stack "$1"; printf 'tool|jq|jq|installer|command -v jq|lazy probe\n' >> "$1/tools"; printf 'smoke_gate "j" -- command -v jq\n' >> "$1/scripts/linux/mise-install.sh"; printf 'smoke_gate "j" -- command -v jq\n' >> "$1/scripts/darwin/mise-install.sh"; }
fixture_red "command -v on a non-shim row" "legal only on the pnpm/yarn rows" mut_command_v_abuse

mut_ext_no_pecl() { # php-shaped: pecl row missing from the loop
  mkdir -p "$1/files" "$1/scripts/linux" "$1/scripts/darwin"
  printf 'tool|uv|uv|mise:uv|uv --version|tool\next|imagick|pecl\n' > "$1/tools"
  printf '[tools]\nuv = "latest"\n' > "$1/files/mise.toml"
  local p
  for p in linux darwin; do
    printf 'smoke_gate "r" -- uv --version\nfor ext in pcov; do\n  :\ndone\nmembership_gate "exts" "$(php -m)" imagick\n' > "$1/scripts/$p/mise-install.sh"
  done
}
fixture_red "pecl row absent from the install loop" "missing from the PECL install loop" mut_ext_no_pecl

mut_memb_drift() { # membership list missing a declared ext
  mkdir -p "$1/files" "$1/scripts/linux" "$1/scripts/darwin"
  printf 'tool|uv|uv|mise:uv|uv --version|tool\next|imagick|pecl\next|gd|bundled\n' > "$1/tools"
  printf '[tools]\nuv = "latest"\n' > "$1/files/mise.toml"
  local p
  for p in linux darwin; do
    printf 'smoke_gate "r" -- uv --version\nfor ext in imagick; do\n  :\ndone\nmembership_gate "exts" "$(php -m)" imagick\n' > "$1/scripts/$p/mise-install.sh"
  done
}
fixture_red "membership token drift" "ext rows missing from membership_gate" mut_memb_drift

mut_fake_listing() { # membership listing replaced with a fabricated one
  mkdir -p "$1/files" "$1/scripts/linux" "$1/scripts/darwin"
  printf 'tool|uv|uv|mise:uv|uv --version|tool\next|imagick|pecl\n' > "$1/tools"
  printf '[tools]\nuv = "latest"\n' > "$1/files/mise.toml"
  local p
  for p in linux darwin; do
    printf 'smoke_gate "r" -- uv --version\nfor ext in imagick; do\n  :\ndone\nmembership_gate "exts" "$(echo imagick)" imagick\n' > "$1/scripts/$p/mise-install.sh"
  done
}
fixture_red "fabricated membership listing" "must be exactly" mut_fake_listing

# ── the holes the CP1 review closed, each pinned red ────────────────────────

mut_heredoc_gate() { # the only gate text lives inside a heredoc body
  mk_stack "$1"
  printf 'cat > /tmp/x <<EOF\nsmoke_gate "runtimes" -- uv --version\nEOF\n' > "$1/scripts/linux/mise-install.sh"
}
fixture_red "gate text only inside a heredoc" "declared proofs missing" mut_heredoc_gate

mut_unterminated()    { mk_stack "$1"; printf 'smoke_gate "runtimes" -- uv --version \\\n' > "$1/scripts/linux/mise-install.sh"; }
fixture_red "unterminated continuation at EOF" "unterminated backslash continuation" mut_unterminated

mut_quoted_group()    { mk_stack "$1"; printf 'smoke_gate "runtimes" -- "uv --version"\n' > "$1/scripts/linux/mise-install.sh"; }
fixture_red "quoted single-token group spelling a two-word proof" "no declaration row" mut_quoted_group

mut_tab_row()         { mk_stack "$1"; printf 'tool|jq|jq|installer\tjq --version||json tool\n' >> "$1/tools"; }
fixture_red "tab character inside a row" "tab character in row" mut_tab_row

mut_empty_proof()     { mk_stack "$1"; printf 'tool|jq|jq|installer||json tool\n' >> "$1/tools"; }
fixture_red "empty proof field" "empty field" mut_empty_proof

mut_node_installer()  { mk_node_stack "$1"; awk -F'|' 'BEGIN{OFS="|"} $2=="node"{$4="installer"} {print}' "$1/tools" > "$1/tools.t" && mv "$1/tools.t" "$1/tools"; printf '[tools]\n\n[settings]\nnode.corepack = true\n' > "$1/files/mise.toml"; }
fixture_red "node row wearing managed-by installer" "must be managed-by mise:node" mut_node_installer

mut_setting_false()   { mk_node_stack "$1"; printf '[tools]\nnode = "lts"\n\n[settings]\nnode.corepack = false\n\n[tool_alias]\nnode.corepack = "true"\n' > "$1/files/mise.toml"; }
fixture_red "settings false with a tool_alias true decoy" "must set node.corepack = true" mut_setting_false

mut_nodeless_false()  { mk_stack "$1"; printf '[tools]\nuv = "latest"\n\n[settings]\nnode.corepack = false\n' > "$1/files/mise.toml"; }
fixture_red "node-less stack carrying node.corepack = false" "any value" mut_nodeless_false

mut_dup_settings()    { mk_node_stack "$1"; printf '[tools]\nnode = "lts"\n\n[settings]\nnode.corepack = true\nnode.corepack = true\n' > "$1/files/mise.toml"; }
fixture_red "duplicate [settings] keys" "duplicate [settings] keys" mut_dup_settings

mut_glob_proof()      { mk_stack "$1"; printf 'tool|jq|jq|installer|jq *|glob probe\n' >> "$1/tools"; }
fixture_red "glob metacharacter in a proof" "argument grammar" mut_glob_proof

mut_memb_no_listing() { mk_stack "$1"; printf 'membership_gate "oops"\n' >> "$1/scripts/linux/mise-install.sh"; }
fixture_red "membership_gate with no listing argument" "no listing argument" mut_memb_no_listing

mut_memb_empty_tok()  { mk_stack "$1"; printf 'ext|imagick|pecl\n' >> "$1/tools"
  printf 'smoke_gate "r" -- uv --version\nfor ext in imagick; do\n  :\ndone\nmembership_gate "exts" "$(php -m)" imagick ""\n' > "$1/scripts/linux/mise-install.sh"
  printf 'smoke_gate "r" -- uv --version\nfor ext in imagick; do\n  :\ndone\nmembership_gate "exts" "$(php -m)" imagick\n' > "$1/scripts/darwin/mise-install.sh"; }
fixture_red "empty quoted membership token" "empty membership token" mut_memb_empty_tok

mut_ext_only()        { mk_stack "$1"; printf 'ext|imagick|pecl\n' > "$1/tools"
  local p; for p in linux darwin; do printf 'for ext in imagick; do\n  :\ndone\nmembership_gate "exts" "$(php -m)" imagick\n' > "$1/scripts/$p/mise-install.sh"; done; }
fixture_red "ext-only declaration (zero tool rows)" "no tool rows" mut_ext_only

printf '\n  %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
