# php

PHP development stack. Builds a `<distro>-php` Tart image (e.g. `fedora-php`) preconfigured with PHP 8.5, Node (Active LTS), and standard backend dev essentials. Intended as a per-project clone source.

For host setup, build flow, daily use, and persistent terminal sessions (zellij), see the [top-level README](../../README.md). This file documents what's in *this* stack specifically.

## What's in this stack

**Version-managed runtimes** (via mise — installed by [`scripts/mise-install.sh`](./scripts/mise-install.sh) per [`files/mise.toml`](./files/mise.toml))

- **Node** — whichever LTS line mise's `lts` alias currently points to (`node = "lts"` in `files/mise.toml`). The alias is hardcoded in mise's source; jdx/mise bumps it shortly after each October LTS cutover, so fresh builds follow with a short lag.
- **PHP 8.5** (pinned to a specific patch in `files/mise.toml`). Standard bundled extensions (DB drivers, GD, intl, mbstring, opcache, etc.) plus PECL adds: **Imagick**, **Redis**, **Memcached**, **PCOV** for coverage (always enabled — run `phpunit --coverage-text` or `--coverage-html=coverage/`), **Xdebug 3** (`XDEBUG_TRIGGER=1` to attach).

**PHP toolchain**

- **Composer** via the official installer (`~/.local/bin/composer`, self-updates with `composer self-update`).

**Stack-specific build dependencies** (installed by [`scripts/00-stack.sh`](./scripts/00-stack.sh))

PHP is compiled from source via mise+vfox-php, the plugin pinned in [`files/mise.toml`](./files/mise.toml)'s `[tool_alias]` so a registry reshuffle upstream cannot swap it. The packages in [`packages.dnf`](./packages.dnf) (Fedora) and [`packages.apt`](./packages.apt) (Debian/Ubuntu) map to specific PHP extensions; the inline comments list which extension each package enables. The install is deliberately tolerant (`pkg_install_optional` warns on an unavailable package rather than failing), so the smoke test at the end of [`scripts/mise-install.sh`](./scripts/mise-install.sh) is the enforcement point: an extension on its gate list that fails to load **fails the build loudly**. Only capabilities outside the gate — e.g. gd's WebP/AVIF/XPM format support, PHP-FPM's systemd notify — can vanish silently, which is why package-list changes must be paired with smoke-list changes.

## Known limitations

- **Playwright `install chrome` fails on Linux ARM64** — Google doesn't ship Chrome stable for ARM64 yet ([Chromium blog, 2026-03](https://blog.chromium.org/2026/03/bringing-chrome-to-arm64-linux-devices.html)). Use `--browser=chromium` (or `channel: 'chromium'` in playwright config) — the bundled Chromium build works. On Fedora, WebKit requires additional native libs not installed by default; run `playwright install-deps webkit` inside the clone to add them.

## Customization

- **Tool versions**: [`files/mise.toml`](./files/mise.toml).
- **Add or drop a PHP extension**: each PHP extension needs its build-dep package in [`packages.dnf`](./packages.dnf) (Fedora) and [`packages.apt`](./packages.apt) (Debian/Ubuntu) — the inline comments list the extension each entry enables (e.g., `libpq-devel` / `libpq-dev` → `pdo_pgsql`). Pair every package change with the matching entry in the smoke-test list in [`scripts/mise-install.sh`](./scripts/mise-install.sh).
- **Per-project version pin**: drop a `.mise.toml` in the project repo root and commit it, then run `mise trust` once inside the repo — project configs are deliberately untrusted until you do (that prompt is the supply-chain gate; a non-interactive agent runs `mise trust` as an explicit step). How much the gate covers moves with the mise release the image happened to install — see the note in [`files/mise.toml`](./files/mise.toml):
  ```toml
  [tools]
  node = "<major>"
  php  = "<major.minor.patch>"   # exact: a fuzzy "8.5" pulls RCs, which sort above the patch they precede
  ```
- **PECL extension list**: edit the for-loop in [`scripts/mise-install.sh`](./scripts/mise-install.sh) (`for ext in pcov xdebug imagick redis memcached; do`). Add to the smoke-test list too so a missing one fails the build.
- **Shell baseline**: [`shared/files/zshrc`](../../shared/files/zshrc) (affects every stack; edit there only if it's not stack-specific).

## Troubleshooting

- **PHP compile fails midway** → mise surfaces the compiler error and the build stops there; the extension gate at the end of `mise-install.sh` never runs (it catches extensions that BUILT but did not load). `packages.dnf` / `packages.apt` (whichever family you're building) maps each extension to its required build-dep package via inline comments. Distro release bumps occasionally rename packages — pin a specific image tag (`IMAGE_TAG=<tag> make bootstrap DISTRO=<distro>`) to roll back while investigating.
- **`composer` command not found inside a VM clone** → confirm mise is wired: `which php` should resolve under `~/.local/share/mise/installs/` in an interactive shell, or `~/.local/share/mise/shims/` in a non-interactive one. If neither, `eval "$(mise activate bash)"` then re-test. The zsh activation ships in the uploaded [`shared/files/zshrc`](../../shared/files/zshrc) baseline (the VM's `~/.zshrc`); `shared/linux/scripts/user-config.sh` adds the bash equivalent to `~/.bashrc` and puts `~/.local/bin` plus mise's shims on PATH via `~/.zshenv` — the shims are what serve `ssh tart-<vm> <cmd>`, which runs the login shell and never reads `~/.zshrc`. A corrupted clone's shell rc may have lost either.
- **`xdebug` doesn't attach** → it's in trigger mode; set `XDEBUG_TRIGGER=1` in env (or send the trigger cookie) before the request. The IDE side needs to listen on port 9003 inside the VM (forward it if the IDE is on the host).
