#!/usr/bin/env bash
# 00-stack.sh — PHP build dependencies for compile-from-source via mise+asdf-php.
# Runs as root via sudo from Packer, immediately after shared/scripts/00-base.sh
# in the same root provisioner block.
#
# PHP's `./configure` enables an extension when both (a) an explicit
# `--with-X` flag is passed AND (b) the header library is on disk.
# asdf-php passes a default flag set (see PHP_CONFIGURE_OPTIONS in
# mise-install.sh for the actual list); these packages provide the
# headers for those flags. Removing a package silently drops the
# corresponding extension from the compiled PHP, with no error pointing
# back at the cause.
#
# Build toolchain (PHP-specific):        re2c pkgconf
# (bison/autoconf/automake/libtool come from development-tools in 00-base.sh)
# Core compile deps (always):            openssl-devel libxml2-devel
# pdo_sqlite, sqlite3:                   sqlite-devel
# mbstring:                              oniguruma-devel
# curl:                                  libcurl-devel
# zip:                                   libzip-devel
# gd (JPEG/PNG/WebP/XPM/AVIF/FreeType):  gd-devel libpng-devel libjpeg-turbo-devel
#                                        libwebp-devel libXpm-devel libavif-devel
#                                        freetype-devel
#                                        (gd-devel is load-bearing — --with-external-gd
#                                        needs gdlib >= 2.1.0; the others are GD's
#                                        optional format helpers.)
# sodium:                                libsodium-devel
# readline:                              libedit-devel readline-devel
# bz2:                                   bzip2-devel
# PHP-FPM systemd notify support:        systemd-devel
# pdo_pgsql:                             libpq-devel
# PECL imagick:                          ImageMagick (runtime) + ImageMagick-devel (headers)
# PECL memcached:                        libmemcached-devel

set -euo pipefail

echo "==> Installing PHP build dependencies..."
dnf install -y --skip-unavailable \
  re2c pkgconf \
  openssl-devel libxml2-devel \
  sqlite-devel \
  oniguruma-devel \
  libcurl-devel \
  libzip-devel \
  gd-devel libpng-devel libjpeg-turbo-devel libwebp-devel libXpm-devel libavif-devel freetype-devel \
  libsodium-devel \
  libedit-devel readline-devel \
  bzip2-devel \
  systemd-devel \
  libpq-devel \
  ImageMagick ImageMagick-devel \
  libmemcached-devel

echo "==> 00-stack.sh (fedora-php) complete."
