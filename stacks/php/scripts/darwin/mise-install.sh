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
# UNVERIFIED — never run against a real macOS build. darwin.pkr.hcl does not
# exist yet (a later task's job), so nothing has invoked this file. What's
# below is grounded in the ACTUAL source of the pinned vfox-php plugin
# (mise.toml's [tool_alias]: vfox:jdx/vfox-php — confirmed a byte-identical
# fork of mise-plugins/vfox-php as of 2026-07, read via its
# hooks/post_install.lua), not guesswork about how PHP configure behaves on
# macOS in general. See task-13-report.md for exactly what that source
# confirmed vs. what is still assumed.
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

# Homebrew's bin dir isn't guaranteed to be on PATH for a script Packer
# invokes directly rather than through a login shell (user-config.sh only adds
# it to .zshenv, which a non-interactive `ssh <vm> <cmd>` reads but a Packer
# shell provisioner may not, depending on its execute_command — a detail owned
# by darwin.pkr.hcl, not written yet). pkg-config, pg_config, and every other
# Homebrew helper the PECL loop below shells out to by bare name live there.
export PATH="/opt/homebrew/bin:$PATH"

# APPEND to vfox-php's configure line; never set PHP_CONFIGURE_OPTIONS, which
# that plugin reads as a full replacement — see the linux peer for why.
#
# Same flags as ../linux/mise-install.sh, unchanged, and deliberately still
# explicit here even though the plugin's own darwin path would add
# --with-sodium/--with-bz2/--with-external-gd/--with-pdo-pgsql automatically
# IF it finds the matching Homebrew formula: that auto-add is presence-based
# and silent on a miss (see the header above), the same silent-skip failure
# mode packages.dnf/apt sidestep by stating flags outright on linux. Passing
# them here means a missing brew formula fails configure loudly instead.
# --with-zip has no such auto-add path on darwin at all (libzip only gets
# PKG_CONFIG_PATH wiring, never a flag) — this is the one flag that is not
# redundant with the plugin's own logic on either platform.
#
# --with-external-gd specifically needs the `gd` formula (packages.brew) for
# its gdlib.pc — php-src's own configure runs PKG_CHECK_MODULES([GDLIB],
# [gdlib >= 2.1.0]) for this flag, and that .pc file ships with `gd` itself,
# NOT with its dependencies. The plugin's own has_gd_deps check (see the
# header above) only verifies freetype/jpeg/libpng are present before adding
# this same flag on its own — none of those three provide gdlib.pc either,
# so that auto-add path has the identical gap. Confirmed on this host via
# `brew info --json gd` (dependencies: fontconfig, freetype, jpeg-turbo,
# libavif, libpng, libtiff, webp — none of which is a substitute for gd
# itself) and by reading gd's shipped gdlib.pc directly. Because this flag is
# FORCED here rather than probed, a missing `gd` formula would not silently
# drop the extension — it would fail php-src's ./configure outright and abort
# the whole PHP build, before this script's PECL loop or smoke gate ever run.
export PHP_EXTRA_CONFIGURE_OPTIONS="--with-sodium --with-bz2 \
--with-external-gd --with-pdo-pgsql --with-zip"

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
for ext in pcov xdebug imagick redis memcached; do
  # Subshell disables pipefail just for this pipeline: `yes` exits 141 on
  # SIGPIPE when pecl closes stdin, which pipefail would misread as failure.
  if (set +o pipefail; yes '' | pecl install "$ext"); then
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
