# php

PHP development stack. Builds a `<os>-php` Tart image (e.g. `fedora-php`) preconfigured with PHP 8.5, Node (Active LTS), and standard backend dev essentials. Intended as a per-project clone source.

For host setup, build flow, daily use, and persistent terminal sessions (zellij), see the [top-level README](../../README.md). This file documents what's in *this* stack specifically.

## What's in this stack

The inventory below is generated from [`tools`](./tools), the stack's canonical tool declaration: every row is hard-gated at build (the installers' `smoke_gate`/`membership_gate` calls are held to it by the test suite) and probed at runtime (`make smoke` runs each Runtime probe over a non-interactive ssh).

<!-- tools:begin -->
<!-- Generated from ./tools by script/stack-docs — edit that file, then run `make docs`. -->
| Tool | Managed by | Build gate | Runtime probe | Purpose |
|---|---|---|---|---|
| node | mise (`node = lts`) | smoke_gate | `node --version` | JS runtime for tooling and mixed projects |
| php | mise (`php = 8.5.8`) | smoke_gate | `php --version` | the PHP runtime, compiled from source via vfox-php |
| composer | the stack's own installer script | smoke_gate | `composer --version` | PHP dependency manager |
| corepack | Corepack (enabled at build by mise_runtime_setup) | smoke_gate | `corepack --version` | package-manager shim dispatcher, ships with Node 24 and earlier |
| pnpm | Corepack (enabled at build by mise_runtime_setup) | smoke_gate | `command -v pnpm` | Corepack shim; resolves per-project via package.json packageManager |
| yarn | Corepack (enabled at build by mise_runtime_setup) | smoke_gate | `command -v yarn` | Corepack shim; resolves per-project via package.json packageManager |
<!-- tools:end -->

### PHP extensions

<!-- extensions:begin -->
<!-- Generated from ./tools by script/stack-docs — edit that file, then run `make docs`. -->
| Extension | Source | Build gate | Runtime probe |
|---|---|---|---|
| pdo_sqlite | bundled | membership_gate | — |
| sqlite3 | bundled | membership_gate | — |
| mysqli | bundled | membership_gate | — |
| pdo_mysql | bundled | membership_gate | — |
| pdo_pgsql | bundled | membership_gate | — |
| gd | bundled | membership_gate | — |
| imagick | pecl | membership_gate | — |
| redis | pecl | membership_gate | — |
| memcached | pecl | membership_gate | — |
| intl | bundled | membership_gate | — |
| mbstring | bundled | membership_gate | — |
| curl | bundled | membership_gate | — |
| json | bundled | membership_gate | — |
| zend opcache | bundled | membership_gate | — |
| sodium | bundled | membership_gate | — |
| readline | bundled | membership_gate | — |
| bz2 | bundled | membership_gate | — |
| zip | bundled | membership_gate | — |
| openssl | bundled | membership_gate | — |
| pcov | pecl | membership_gate | — |
| xdebug | pecl | membership_gate | — |
<!-- extensions:end -->

**Notes**

- **Node** — whichever LTS line mise's `lts` alias currently points to (`node = "lts"` in `files/mise.toml`). The alias is hardcoded in mise's source; jdx/mise bumps it shortly after each October LTS cutover, so fresh builds follow with a short lag.
- **PHP** — pinned to a specific patch in `files/mise.toml`; compiled from source via mise+vfox-php. **PCOV is always enabled** — run `phpunit --coverage-text` or `--coverage-html=coverage/`; disable per-command with `php -d pcov.enabled=0`. **Xdebug 3** is in trigger mode: `XDEBUG_TRIGGER=1` to attach.
- **Composer** — official installer (`~/.local/bin/composer`, self-updates with `composer self-update`).
- **Corepack shims** — `pnpm`/`yarn` resolve per project via `package.json`'s `packageManager`. The shims exist for Nodes that bundle Corepack (24 and earlier); a project-pinned Node 25+ gets no shims from either the mise setting or the build's enable step — provision Corepack yourself in that case.

**Stack-specific build dependencies** (installed by [`scripts/00-stack.sh`](./scripts/00-stack.sh))

PHP is compiled from source via mise+vfox-php, the plugin pinned in [`files/mise.toml`](./files/mise.toml)'s `[tool_alias]` so a registry reshuffle upstream cannot swap it. The packages in [`packages.dnf`](./packages.dnf) (Fedora), [`packages.apt`](./packages.apt) (Debian/Ubuntu), and [`packages.brew`](./packages.brew) (darwin) map to specific PHP extensions; the inline comments list which extension each package enables. The install is deliberately tolerant (`pkg_install_optional` warns on an unavailable package rather than failing), so the smoke test at the end of [`scripts/linux/mise-install.sh`](./scripts/linux/mise-install.sh) / [`scripts/darwin/mise-install.sh`](./scripts/darwin/mise-install.sh) is the enforcement point: an extension on its gate list that fails to load **fails the build loudly**. Only capabilities outside the gate — e.g. gd's WebP/AVIF/XPM format support, PHP-FPM's systemd notify — can vanish silently, which is why package-list changes must be paired with smoke-list changes.

## Known limitations

- **Playwright `install chrome` fails on Linux ARM64** — Google doesn't ship Chrome stable for ARM64 yet ([Chromium blog, 2026-03](https://blog.chromium.org/2026/03/bringing-chrome-to-arm64-linux-devices.html)). Use `--browser=chromium` (or `channel: 'chromium'` in playwright config) — the bundled Chromium build works. On Fedora, WebKit requires additional native libs not installed by default; run `playwright install-deps webkit` inside the clone to add them.

## Customization

- **Tool versions**: [`files/mise.toml`](./files/mise.toml).
- **Add or drop a PHP extension**: each PHP extension needs its build-dep package in [`packages.dnf`](./packages.dnf) (Fedora), [`packages.apt`](./packages.apt) (Debian/Ubuntu), and [`packages.brew`](./packages.brew) (darwin) — the inline comments list the extension each entry enables (e.g., `libpq-devel` / `libpq-dev` / `libpq` → `pdo_pgsql`). Then add the `ext|` row in [`tools`](./tools), the matching `membership_gate` token in both [`scripts/linux/mise-install.sh`](./scripts/linux/mise-install.sh) and [`scripts/darwin/mise-install.sh`](./scripts/darwin/mise-install.sh), and run `make docs` — `make test` fails until all three agree.
- **Per-project version pin**: drop a `.mise.toml` in the project repo root and commit it, then run `mise trust` once inside the repo — project configs are deliberately untrusted until you do (that prompt is the supply-chain gate; a non-interactive agent runs `mise trust` as an explicit step). How much the gate covers moves with the mise release the image happened to install — see the note in [`files/mise.toml`](./files/mise.toml):
  ```toml
  [tools]
  node = "<major>"
  php  = "<major.minor.patch>"   # exact: a fuzzy "8.5" pulls RCs, which sort above the patch they precede
  ```
- **PECL extension list**: edit the for-loop (identical in both) in [`scripts/linux/mise-install.sh`](./scripts/linux/mise-install.sh) and [`scripts/darwin/mise-install.sh`](./scripts/darwin/mise-install.sh) (`for ext in pcov xdebug imagick redis memcached; do`), with the matching `ext|<name>|pecl` row in [`tools`](./tools) and `membership_gate` token — the test suite holds all three to equality, so a missing one fails `make test` before it can fail a build.
- **Shell baseline**: [`shared/files/zshrc`](../../shared/files/zshrc) (affects every stack; edit there only if it's not stack-specific).

## Troubleshooting

- **PHP compile fails midway** → mise surfaces the compiler error and the build stops there; the extension gate at the end of `mise-install.sh` never runs (it catches extensions that BUILT but did not load). `packages.dnf` / `packages.apt` / `packages.brew` (whichever family you're building) maps each extension to its required build-dep package via inline comments. OS release bumps occasionally rename packages — pin a specific image tag (`IMAGE_TAG=<tag> make bootstrap OS=<os>`) to roll back while investigating.
- **`composer` command not found inside a VM clone** → confirm mise is wired: `which php` should resolve under `~/.local/share/mise/installs/` in an interactive shell, or `~/.local/share/mise/shims/` in a non-interactive one. If neither, `eval "$(mise activate bash)"` then re-test. The zsh activation ships in the uploaded [`shared/files/zshrc`](../../shared/files/zshrc) baseline (the VM's `~/.zshrc`); `shared/linux/scripts/user-config.sh` adds the bash equivalent to `~/.bashrc` and puts `~/.local/bin` plus mise's shims on PATH via `~/.zshenv` — the shims are what serve `ssh tart-<vm> <cmd>`, which runs the login shell and never reads `~/.zshrc`. A corrupted clone's shell rc may have lost either.
- **`xdebug` doesn't attach** → it's in trigger mode; set `XDEBUG_TRIGGER=1` in env (or send the trigger cookie) before the request. The IDE side needs to listen on port 9003 inside the VM (forward it if the IDE is on the host).
