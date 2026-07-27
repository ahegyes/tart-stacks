#!/usr/bin/env bash
# mise-install.sh (darwin) — install language runtimes declared in the global
# mise.toml, exactly like the linux peer at ../linux/mise-install.sh. The only
# real difference is library discovery: Homebrew keeps several formulas
# "keg-only" (their .pc files live under their own opt/ prefix, e.g.
# /opt/homebrew/opt/icu4c/lib/pkgconfig, instead of the shared
# /opt/homebrew/lib/pkgconfig every non-keg-only formula's .pc lands in — the
# path pkg-config, once installed via Homebrew, already searches by default),
# and macOS ships neither OpenSSL nor a linkable ICU of its own.
#
# Runs as the unprivileged SSH user (mise installs to ~/.local/share/mise/).
#
# This exact file has run to completion — exit 0, every gate below passing —
# on macos-probe, the project's dedicated macOS measurement VM: mise_runtime_setup
# (node, then php compiling from source through `make install`), the PECL
# loop (pcov/xdebug/imagick/redis/memcached all built), smoke_gate,
# membership_gate's full token list, and the Composer install. What that
# proves and what it doesn't: macos-probe is booted and driven directly
# (`tart run` + ssh), not through darwin.pkr.hcl's own Packer provisioner
# chain, so 00-base.sh/00-stack.sh/user-config.sh/99-finalize.sh and the
# file-upload sequence around this script are still unproven by an actual
# `make build` — only this script's own logic, run the same way Packer
# invokes it (no execute_command override, packages.brew's formulas
# pre-installed), is confirmed. What's below is grounded in the ACTUAL
# source of the pinned vfox-php plugin (mise.toml's [tool_alias]:
# vfox:jdx/vfox-php — confirmed a byte-identical fork of mise-plugins/vfox-php
# as of 2026-07, read via its hooks/post_install.lua), php-src's own
# config.m4 at the pinned php-8.5.8 tag, and the measurements above — not
# guesswork about how PHP configure behaves on macOS in general. See
# task-13-report.md for exactly what those sources confirmed vs. what is
# still assumed.
#
# What the plugin's darwin path does on its own (informing what this script
# does NOT need to repeat): reads HOMEBREW_PREFIX (defaults /opt/homebrew) and
# builds PKG_CONFIG_PATH from a hardcoded list of formulas — bison, re2c
# (PATH-only), icu4c (version-probed, e.g. icu4c@78), krb5, libedit, libxml2,
# openssl@3, zlib, libzip, oniguruma, sqlite, curl — then separately appends a
# --with-X flag for each of gmp, libsodium, freetype, gettext, jpeg, webp,
# libpng, readline, bzip2, libiconv, libpq that it finds installed, plus
# --with-external-gd if freetype+jpeg+libpng are all present. None of this is
# a hard gate on the plugin's own side — a missing formula prints a warning
# and the build continues without that capability, which is exactly the
# "silent capability loss" packages.brew's own header describes; the smoke
# gate below is what turns that into a build failure instead.

set -euo pipefail
# /tmp/mise-lib.sh is staged on the guest by the Packer template (absent at lint time).
# shellcheck source=/dev/null
source /tmp/mise-lib.sh

# Homebrew's bin dir isn't guaranteed to be on PATH for this script: the
# mise-install.sh provisioner in darwin.pkr.hcl sets no execute_command
# override, so Packer runs it through its own default — chmod +x the
# uploaded script, then exec it directly — rather than through a login
# shell, so none of the startup files only a login invocation sources (e.g.
# ~/.zprofile) ever run here. pkg-config, pg_config, and every other
# Homebrew helper the PECL loop below shells out to by bare name live there.
export PATH="/opt/homebrew/bin:$PATH"

# bison is keg-only (unlike re2c, already reachable via /opt/homebrew/bin
# above), and macOS's own /usr/bin/bison is Apple's last-GPLv2 release
# (2.3), missing options modern generated grammars need. The vfox-php
# plugin's own PATH/PKG_CONFIG_PATH construction (see the header above)
# wraps only the ./configure invocation itself; `make`, a separate
# subprocess the plugin runs afterward with no such prefix, re-resolves a
# bare `bison` from whatever PATH this script itself set — finding the
# system one unless it's added here too. Measured on the project's
# macos-probe rig (kept for exactly this kind of iteration): configure's own
# bison check passes ("3.8.2 (ok)") under the plugin's one-shot PATH, then
# `make` invokes bare `bison` regenerating ext/json/json_parser.tab.c and
# fails ("invalid option -- W") against /usr/bin/bison's 2.3.
BISON_PREFIX="$(brew --prefix bison)"
export PATH="${BISON_PREFIX}/bin:$PATH"

# APPEND to vfox-php's configure line; never set PHP_CONFIGURE_OPTIONS, which
# that plugin reads as a full replacement — see the linux peer for why.
#
# Every flag below is stated explicitly rather than left to the plugin's own
# presence-based auto-add (see the header above) so a missing brew formula
# fails configure loudly instead of silently shipping a smaller PHP — same
# reasoning as packages.dnf/apt on linux. --with-bz2 and --with-pdo-pgsql
# additionally need an explicit directory: their php-src config.m4 (read at
# the pinned php-8.5.8 tag) does a raw header/pg_config path search with no
# pkg-config fallback, and bzip2/libpq are two of packages.brew's twelve
# keg-only formulas — Homebrew never symlinks their headers into the shared
# /opt/homebrew/include every non-keg-only formula lands in, only under their
# own $(brew --prefix <formula>). A bare --with-bz2/--with-pdo-pgsql here
# doesn't just fail to help — PHP_EXTRA_CONFIGURE_OPTIONS is appended AFTER
# the plugin's own configure string, so a bare flag here OVERRIDES the
# correctly-path-qualified one the plugin's optional_packages logic already
# added (autoconf's last-flag-wins), reverting the search to a pathless
# "yes" that only checks /usr/local and /usr — never where Homebrew puts a
# keg-only formula. Measured on macos-probe: that is the exact failure
# ("bzlib.h not found") a real build hit; pdo_pgsql was the identical latent
# bug, confirmed on the same rig once bz2 was out of the way.
#
# --with-openssl is here because the plugin's own darwin path never adds it
# at all — unlike its Linux path, which does (see the header above: darwin's
# required_packages/optional_packages loops wire openssl@3 into
# PKG_CONFIG_PATH but never add the --with-openssl flag PHP's
# PHP_SETUP_OPENSSL macro needs to attempt detection in the first place).
# Measured on macos-probe: without it, `./configure` reports "checking for
# OpenSSL support... no" and PHP builds with no openssl extension and no
# https:// stream wrapper at all — silent, since this repo's smoke gate
# never checked for openssl on either platform (a pre-existing gap this task
# did not introduce; see task-13-report.md). ext/openssl's own config.m4 is
# PKG_CHECK_MODULES-only, same as sodium/zip, so the flag stays bare.
#
# --with-sodium/--with-zip/--with-external-gd also stay bare: none of
# libsodium/libzip/gd is keg-only, and none of their config.m4 accepts a
# directory argument at all (each is PKG_CHECK_MODULES-only, or for
# external-gd a plain boolean with no [=DIR] in its own AS_HELP_STRING) — the
# default pkg-config search, which already includes the shared
# /opt/homebrew/lib/pkgconfig (confirmed empirically), finds all three
# without help. --with-external-gd's own target is `gdlib.pc`, shipped by
# the `gd` formula (packages.brew) specifically — confirmed by reading
# php-src's ext/gd/config.m4 directly: the external-gd branch is exactly
# `PKG_CHECK_MODULES([GDLIB], [gdlib >= 2.1.0])`, nothing else.
#
# Declared then exported separately (not `export X=$(...)`) so a failing
# `brew --prefix` isn't masked by the assignment's own exit status — SC2155.
PHP_EXTRA_CONFIGURE_OPTIONS="--with-openssl --with-sodium --with-bz2=$(brew --prefix bzip2) \
--with-external-gd --with-pdo-pgsql=$(brew --prefix libpq) --with-zip"
export PHP_EXTRA_CONFIGURE_OPTIONS

echo "==> Node ~30s, PHP ~5-10 min from source compile"
mise_runtime_setup

# Install PECL extensions. `yes ''` answers interactive prompts with defaults.
# We track per-extension success so we only emit ini files for extensions
# whose .so actually built — writing an ini for a missing .so produces
# "Unable to load dynamic library" warnings on every PHP startup.
echo ""
echo "==> Installing PECL extensions (pcov, xdebug, imagick, redis, memcached)..."
# PEAR refreshes its channel metadata lazily, racing the first install: that one
# can fail with "does not have REST dependency information available" while the
# refresh it triggers leaves every later extension fine. The casualty is always
# whichever runs first, so it reads as pcov being flaky rather than as ordering.
# Best-effort on purpose — an unreachable channel leaves the bundled metadata in
# place, which is the behaviour without this line, and the gate below still rules.
pecl channel-update pecl.php.net \
  || echo "WARNING: pecl channel-update failed; continuing with bundled channel metadata." >&2

# `declare -A` (the linux peer's mechanism) is bash 4+. The guest's
# #!/usr/bin/env bash resolves whatever bash the SSH session's PATH finds
# FIRST — ahead of this script's own PATH export above, which only takes
# effect once the shell is already running — and macOS still ships bash 3.2
# with no associative arrays at all (measured on this host, whose /bin/bash
# is the same 3.2 a macOS guest ships: `/bin/bash -c 'declare -A x=()'` →
# "declare: -A: invalid option"); packages.brew installs no newer bash either.
# Track success as a delimited string instead — same membership idiom as
# bin/tart-ssh-sync's `seen` variable (`case "$seen" in *"|$vm|"*)`).
pecl_ok="|"
pecl_installed() { case "$pecl_ok" in *"|$1|"*) return 0 ;; *) return 1 ;; esac; }

# memcached's own build (PECL's, entirely separate from php-src's ./configure
# above) interactively prompts for --with-zlib-dir; zlib is keg-only, and an
# empty answer resolves to --with-zlib-dir=no — the same class of failure
# bz2/pdo_pgsql hit above, just in a third, independent build script. `pecl
# install -D with-zlib-dir=...` (its documented way to pre-answer a prompt)
# crashes this PHP version's bundled PEAR installer outright — measured on
# the project's macos-probe rig: a TypeError in PEAR/Builder.php, unrelated
# to zlib itself — so the answer is supplied positionally instead: measured
# on the same rig, --with-zlib-dir is the 2nd of memcached's interactive
# prompts (1st: --with-libmemcached-dir, fine left at its "no" default since
# libmemcached isn't keg-only), followed by five more that also default
# safely to "no"/"yes" on an empty answer.
pecl_install_one() {
  case "$1" in
    memcached)
      printf '\n%s\n\n\n\n\n\n\n\n\n\n' "$(brew --prefix zlib)" | pecl install "$1"
      ;;
    *)
      yes '' | pecl install "$1"
      ;;
  esac
}
for ext in pcov xdebug imagick redis memcached; do
  # Subshell disables pipefail just for this pipeline: `yes`/`printf` exits
  # 141 on SIGPIPE when pecl closes stdin, which pipefail would misread as
  # failure.
  if (set +o pipefail; pecl_install_one "$ext"); then
    pecl_ok="${pecl_ok}${ext}|"
  else
    echo "WARNING: pecl install $ext failed — ini file will be skipped." >&2
  fi
done

PHP_SCAN_DIR=$(php -r 'echo PHP_CONFIG_FILE_SCAN_DIR;')
if [ -z "$PHP_SCAN_DIR" ]; then
  echo "ERROR: PHP_CONFIG_FILE_SCAN_DIR is empty. Either php is not on PATH" >&2
  echo "       (mise activate didn't run / failed above) or PHP was built without" >&2
  echo "       a scan dir. Cannot write extension ini files." >&2
  exit 1
fi
mkdir -p "$PHP_SCAN_DIR"

# Always-on extensions (image processing, caching clients). Each ini is
# only written if the corresponding pecl install succeeded — otherwise
# PHP startup would warn about a missing .so on every invocation.
if pecl_installed imagick; then
  cat > "$PHP_SCAN_DIR/20-imagick.ini" <<'EOF'
extension=imagick.so
EOF
fi
if pecl_installed redis; then
  cat > "$PHP_SCAN_DIR/21-redis.ini" <<'EOF'
extension=redis.so
EOF
fi
if pecl_installed memcached; then
  cat > "$PHP_SCAN_DIR/22-memcached.ini" <<'EOF'
extension=memcached.so
EOF
fi

# Coverage driver. Always enabled (significantly lower overhead than
# Xdebug coverage mode); disable per-command with
# `php -d pcov.enabled=0 ...` if measuring uninstrumented perf.
if pecl_installed pcov; then
  cat > "$PHP_SCAN_DIR/30-pcov.ini" <<'EOF'
extension=pcov.so
; Coverage is always available — run `phpunit --coverage-text` or
; `phpunit --coverage-html=coverage/`. Disable per-command with
; `php -d pcov.enabled=0 ...` if measuring uninstrumented perf.
pcov.enabled=1
EOF
fi

# Step debugger. Loaded but inactive; trigger-mode means it only attaches
# when XDEBUG_TRIGGER=1 in env or a trigger cookie is present.
if pecl_installed xdebug; then
  cat > "$PHP_SCAN_DIR/40-xdebug.ini" <<'EOF'
zend_extension=xdebug.so
; 'develop' = nicer var_dump and notices; 'debug' = step debugging.
; Coverage is handled by PCOV, not Xdebug, to avoid driver conflicts.
xdebug.mode=develop,debug
xdebug.start_with_request=trigger
xdebug.discover_client_host=true
xdebug.client_port=9003
EOF
fi

echo "    ini files written to $PHP_SCAN_DIR/"

# Smoke test — HARD GATE. The Packer build fails if any expected extension
# is missing (built-in or PECL). This catches both compile failures and
# pecl install failures, so we never produce a green build with broken
# extension wiring that only surfaces at first PHP invocation in a clone.
smoke_gate "runtimes" -- node --version -- php --version
membership_gate "PHP extensions" "$(php -m)" \
    pdo_sqlite sqlite3 \
    mysqli pdo_mysql \
    pdo_pgsql \
    gd imagick \
    redis memcached \
    intl mbstring curl json 'zend opcache' \
    sodium readline bz2 zip \
    pcov xdebug

# Composer — official installer. Composer isn't bundled with PHP the way
# npm is with Node, so we install it explicitly alongside the PHP runtime.
# Integrity check per Composer's own docs: https://getcomposer.org/download/
# Self-updates thereafter via `composer self-update`.
echo ""
echo "==> Installing Composer (official installer)..."
COMPOSER_INSTALL_DIR="$HOME/.local/bin"
mkdir -p "$COMPOSER_INSTALL_DIR"
EXPECTED_CHECKSUM=$(curl -fsSL --retry 3 --retry-delay 2 https://composer.github.io/installer.sig)
curl -fsSL --retry 3 --retry-delay 2 https://getcomposer.org/installer -o /tmp/composer-setup.php
ACTUAL_CHECKSUM=$(php -r "echo hash_file('SHA384', '/tmp/composer-setup.php');")
if [ "$EXPECTED_CHECKSUM" != "$ACTUAL_CHECKSUM" ]; then
  echo "ERROR: Composer installer checksum mismatch (expected $EXPECTED_CHECKSUM, got $ACTUAL_CHECKSUM)." >&2
  rm -f /tmp/composer-setup.php
  exit 1
fi
php /tmp/composer-setup.php --quiet --install-dir="$COMPOSER_INSTALL_DIR" --filename=composer
rm -f /tmp/composer-setup.php
composer --version

echo ""
echo "==> mise-install.sh complete."
