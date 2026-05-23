# fedora-php

PHP development stack. Builds a `fedora-php` Tart image preconfigured with PHP 8.5, Node (Active LTS), Docker, and standard backend dev essentials. Intended as a per-project clone source.

For host setup, build flow, daily use, and persistent terminal sessions (zellij), see the [top-level README](../../README.md). This file documents what's in *this* stack specifically.

## What's in this stack

**Version-managed runtimes** (via mise — installed by [`scripts/mise-install.sh`](./scripts/mise-install.sh) per [`files/mise.toml`](./files/mise.toml))

- **Node** — whichever LTS line mise's `lts` alias currently points to (`node = "lts"` in `files/mise.toml`). The alias is hardcoded in mise's source; jdx/mise bumps it shortly after each October LTS cutover, so fresh builds follow with a short lag.
- **PHP 8.5** (pinned to a specific patch in `files/mise.toml`). Standard bundled extensions (DB drivers, GD, intl, mbstring, opcache, etc.) plus PECL adds: **Imagick**, **Redis**, **Memcached**, **PCOV** for coverage (always enabled — run `phpunit --coverage-text` or `--coverage-html=coverage/`), **Xdebug 3** (`XDEBUG_TRIGGER=1` to attach).

**PHP toolchain**

- **Composer** via the official installer (`~/.local/bin/composer`, self-updates with `composer self-update`).

**Stack-specific build dependencies** (installed by [`scripts/00-stack.sh`](./scripts/00-stack.sh))

PHP is compiled from source via mise+asdf-php. The `*-devel` packages installed by `00-stack.sh` map to specific PHP extensions; removing a `-devel` package silently drops its extension from the next build. See the comment block at the top of `00-stack.sh` for the full mapping.

## Known limitations

- **Playwright `install chrome` fails on Linux ARM64** — Google doesn't ship Chrome stable for ARM64 yet ([Chromium blog, 2026-03](https://blog.chromium.org/2026/03/bringing-chrome-to-arm64-linux-devices.html)). Use `--browser=chromium` (or `channel: 'chromium'` in playwright config) — the bundled Chromium build works. WebKit on Fedora needs manual libs.

## Customization

- **Tool versions**: [`files/mise.toml`](./files/mise.toml).
- **Add or drop a PHP extension**: each PHP extension is gated by a corresponding `-devel` package in [`scripts/00-stack.sh`](./scripts/00-stack.sh) (e.g., `libpq-devel` → `pdo_pgsql`, `openldap-devel` → `ldap`). See the comment block above the dnf install in that script for the full mapping. Removing a `-devel` package drops its extension from the next build; adding one enables a new extension.
- **Per-project version pin**: drop a `.mise.toml` in the project repo root and commit it:
  ```toml
  [tools]
  node = "<major>"
  php  = "<major.minor>"
  ```
- **PECL extension list**: edit the for-loop in [`scripts/mise-install.sh`](./scripts/mise-install.sh) (`for ext in pcov xdebug imagick redis memcached; do`). Add to the smoke-test list too so a missing one fails the build.
- **Shell baseline**: [`shared/files/zshrc`](../../shared/files/zshrc) (affects every stack; edit there only if it's not stack-specific).

## Troubleshooting

- **PHP compile fails midway** → the smoke test at the end of `mise-install.sh` names the missing extension; the comment block in `00-stack.sh` maps each extension to its required `-devel` package. Fedora release bumps occasionally rename packages — pin a specific Fedora tag in the Makefile (instead of `:latest`) to roll back while investigating.
- **`composer` command not found inside a VM clone** → confirm mise activated: `which php` should resolve under `~/.local/share/mise/installs/`. If not, `eval "$(mise activate bash)"` then re-test; the `shared/scripts/user-config.sh` adds this to `~/.bashrc` and `~/.zshrc` automatically, but a corrupted clone's shell rc may have lost it.
- **`xdebug` doesn't attach** → it's in trigger mode; set `XDEBUG_TRIGGER=1` in env (or send the trigger cookie) before the request. The IDE side needs to listen on port 9003 inside the VM (forward it if the IDE is on the host).
