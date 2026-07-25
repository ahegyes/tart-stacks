#!/usr/bin/env bash
# mise-install.sh — Install language runtimes declared in the global
# mise.toml so the base image ships with them ready to use (and every VM
# cloned from this base inherits them).
#
# Runs as the unprivileged SSH user (mise installs to ~/.local/share/mise/).
#
# Timing: Node (LTS) is a pre-built binary download (~30 seconds). PHP is
# compiled from source via the vfox-php plugin and takes 5-10 minutes on
# Apple Silicon. PHP build dependencies are installed by 00-stack.sh.

set -euo pipefail
# /tmp/mise-lib.sh is staged on the guest by the Packer template (absent at lint time).
# shellcheck source=/dev/null
source /tmp/mise-lib.sh

# APPEND to vfox-php's configure line; never set PHP_CONFIGURE_OPTIONS, which
# that plugin reads as a full replacement — everything it supplies unasked would
# go with it, including --with-pear (pecl, used below) and the
# --with-config-file-scan-dir this script writes ini files into. mise.toml pins
# the plugin so these two variables can't be read by the other one.
#
# sodium and bz2 are absent from vfox-php's set. The rest it derives from probes
# (pkg-config libpng/libzip, pg_config) that a missing build dep turns into a
# silently smaller PHP; stating them makes configure fail loudly instead. Every
# flag here backs an extension the smoke gate below requires.
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
declare -A pecl_ok=()
for ext in pcov xdebug imagick redis memcached; do
  # Subshell disables pipefail just for this pipeline: `yes` exits 141 on
  # SIGPIPE when pecl closes stdin, which pipefail would misread as failure.
  if (set +o pipefail; yes '' | pecl install "$ext"); then
    pecl_ok[$ext]=1
  else
    echo "WARNING: pecl install $ext failed — ini file will be skipped." >&2
    pecl_ok[$ext]=0
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
if [ "${pecl_ok[imagick]:-0}" = "1" ]; then
  cat > "$PHP_SCAN_DIR/20-imagick.ini" <<'EOF'
extension=imagick.so
EOF
fi
if [ "${pecl_ok[redis]:-0}" = "1" ]; then
  cat > "$PHP_SCAN_DIR/21-redis.ini" <<'EOF'
extension=redis.so
EOF
fi
if [ "${pecl_ok[memcached]:-0}" = "1" ]; then
  cat > "$PHP_SCAN_DIR/22-memcached.ini" <<'EOF'
extension=memcached.so
EOF
fi

# Coverage driver. Always enabled (significantly lower overhead than
# Xdebug coverage mode); disable per-command with
# `php -d pcov.enabled=0 ...` if measuring uninstrumented perf.
if [ "${pecl_ok[pcov]:-0}" = "1" ]; then
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
if [ "${pecl_ok[xdebug]:-0}" = "1" ]; then
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
echo ""
echo "==> Smoke test (hard gate):"
echo -n "node: "; node --version
echo -n "php:  "; php --version | head -1
echo ""
echo "PHP extensions:"
missing=0
modules=$(php -m)
for ext in \
    pdo_sqlite sqlite3 \
    mysqli pdo_mysql \
    pdo_pgsql \
    gd imagick \
    redis memcached \
    intl mbstring curl json 'zend opcache' \
    sodium readline bz2 zip \
    pcov xdebug; do
  printf "  %-12s " "$ext"
  # Case-insensitive containment: opcache shows as "Zend OPcache" in the list.
  if grep -qiF "$ext" <<<"$modules"; then
    echo "loaded"
  else
    echo "(missing)"
    missing=$((missing + 1))
  fi
done

if [ "$missing" -gt 0 ]; then
  echo ""
  echo "ERROR: $missing expected PHP extension(s) did not load. Fix the build environment and re-run." >&2
  exit 1
fi

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
