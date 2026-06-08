# tart-stacks

Multi-distro, multi-stack collection of Packer templates that build Tart base VM images preconfigured for various language toolchains on Apple Silicon. Supports Fedora, Ubuntu, and Debian (all listed in `shared/distros`). Each stack is cloned per-project; each project VM is independent of the base.

## What's here

```
.
├── README.md  CLAUDE.md  AGENTS.md  SECURITY.md  CONTRIBUTING.md  LICENSE
├── Makefile                            # Single top-level Makefile; `make setup` installs host tools; STACK=<name> selects stack for init/build/rebuild
├── bin/
│   ├── tart-new                        # Creates a project VM by cloning a stack base image, with the validation `tart clone` lacks (stack exists, image built, no name collision) + `--cpu`/`--memory`/`--disk-size` pass-through
│   ├── tart-ssh-sync                   # Regenerates ~/.ssh/config.d/tart-vms as a `tart-*` wildcard (per-connect IP resolution + interactive-login auto-start hook); aliases use the `tart-<name>` prefix
│   ├── tart-up                         # Starts a stopped VM (+ mounts) and waits for SSH on :22; the hook the auto-start Match line fires on an interactive `ssh tart-<name>` (also runnable directly to pre-warm). Accepts bare or `tart-`-prefixed name
│   └── tart-supervise                  # Keeps a VM running across abrupt `tart run` exits (e.g. an Apple Virtualization.framework vsock trap): a per-VM LaunchAgent that clears the wedged state and restarts via tart-up. --install/--uninstall/--status/--once
├── script/
│   ├── setup                           # Host install run by `make setup` (symlinks commands, zsh completion, idempotent SSH Include + catch-all check, forwards + mounts scaffold)
│   └── test                            # Runs the test suite (test/*.sh); invoked by `make test` and the CI tests job
├── completions/
│   └── _tart-new                       # Zsh completion for tart-new (stack token, arg 2); installed by `make setup`
├── test/
│   ├── tart-new.sh                     # Characterization tests for tart-new (validation gates + clone/set wiring; mocks tart, fixture stacks/)
│   ├── tart-up.sh                      # Characterization tests for tart-up's runtime flow (resolve/prefix, base-image refusal, stopped→run w/ netpolicy + mounts, hostname; mocks tart + nc)
│   ├── tart-supervise.sh               # Characterization tests for tart-supervise (--once restart cycle; install/uninstall/status LaunchAgent wiring; mocks tart/tart-up/pgrep/launchctl)
│   ├── parsing.sh                      # Characterization tests for the tart-up + tart-ssh-sync config-line parsers
│   └── distro-lib.sh                   # Characterization test for distro-lib's _detect_family (os-release ID/ID_LIKE → dnf|apt)
├── shared/                             # Stack-agnostic — runs verbatim in every stack's build
│   ├── scripts/
│   │   ├── 00-base.sh                  # First. System update + core dev pkgs + build toolchain + zellij via distro-lib.sh (root)
│   │   ├── 99-finalize.sh              # LAST. Authorize SSH key + sshd drop-in + NOPASSWD sudo + lock admin password (root)
│   │   ├── distro-lib.sh               # Package-manager abstraction: pkg_install/pkg_refresh/repo_add_mise/install_zellij etc. for dnf (Fedora) and apt (Debian/Ubuntu) families
│   │   ├── mise-lib.sh                 # Shared helpers sourced by each stack's mise-install.sh (uploaded to /tmp; not run directly)
│   │   ├── mise.sh                     # mise install system-wide via repo_add_mise (uses COPR on dnf, signed apt repo on apt) (root)
│   │   ├── terminfo.sh                 # Compile vendored xterm-ghostty terminfo, which ncurses-term omits (root)
│   │   └── user-config.sh              # zsh default shell + mise/PATH activation for bash & non-interactive shells (root)
│   └── files/
│       ├── xterm-ghostty.terminfo      # Ghostty terminfo source; compiled by terminfo.sh into the image
│       └── zshrc                       # In-VM shell baseline; uploaded to /home/admin/.zshrc
├── stacks/
│   ├── php/                            # PHP stack — per-stack content only; the template is the repo-root stack.pkr.hcl
│   │   ├── scripts/
│   │   │   ├── 00-stack.sh             # Runs immediately after shared/00-base.sh; reads packages.<family> via distro-lib.sh (root)
│   │   │   └── mise-install.sh         # Installs PHP/Node from mise.toml + PECL + Composer + smoke test (user)
│   │   ├── files/
│   │   │   └── mise.toml               # In-VM global tool versions (pinned PHP patch + Node LTS)
│   │   ├── packages.dnf                # Native build deps for dnf-family (Fedora/RHEL); one package per line, comments stripped
│   │   ├── packages.apt                # Native build deps for apt-family (Debian/Ubuntu); equivalent capabilities to packages.dnf
│   │   └── README.md                   # Stack-specific docs (what's installed, customization, troubleshooting)
│   └── jvm/                            # JVM stack — same shape; Temurin 25 + Maven/Gradle/sbt/Kotlin/scala-cli + uv + Node
└── .github/
    └── workflows/
        └── validate.yml                # packer validate + shellcheck on push/PR to trunk; matrix covers every stacks/* × shared/distros cell
```

## Conventions

- **`AGENTS.md` is canonical.** `CLAUDE.md` is a one-line `@AGENTS.md` import. AGENTS.md is the standard recognized by Codex, Cursor, Cline, etc.
- **Every shell script starts with `set -euo pipefail`.** No exceptions.
- **Comments explain WHY, not WHAT.** Don't restate the code; explain hidden constraints, load-order requirements, or surprising behavior.
- **Function naming: `tart_` prefix marks functions sourced from `bin/lib/`; script-local helpers stay bare.** A prefixed call (`tart_need_cmd`, `tart_config_path`) signals "defined in the lib, not this file"; a bare one (`dir_args`, `resolve_pattern`) is local. The prefix only carries that signal while it stays selective — don't add it to local helpers.
- **Naming is `tart-stacks` everywhere** for the repo. Stack directories are bare tokens (`php`, `jvm`). The Tart image name is `<distro>-<stack>` (e.g. `fedora-php`, `ubuntu-jvm`) — the distro prefix comes from the `-var distro=` build arg, not the stack dir name. Don't introduce alternative spellings within a stack's files.
- **Host (macOS) and guest (VM) live in the same repo.** `bin/tart-up` and `bin/tart-ssh-sync` run on the host; `make`/`packer` run on the host; everything under `shared/scripts/`, `shared/files/`, and `stacks/*/scripts/`, `stacks/*/files/` runs inside the build VM.
- **`script/` (singular) vs `scripts/` (plural) is deliberate, not a typo.** Three directories, three roles: `bin/` = user commands symlinked onto `$PATH` (`tart-up`, `tart-ssh-sync`, `tart-new`); `script/` = the [Scripts to Rule Them All](https://github.com/github/scripts-to-rule-them-all) namespace for host dev-tasks run via `make`, never on `$PATH` (`setup`, `test`); `scripts/` under `shared/` and `stacks/*/` = in-VM provisioner collections, each paired with a sibling `files/`.
- **`shared/` vs `stacks/<name>/` rule.** A file goes in `shared/` if it would be byte-identical across every plausible stack. Anything that differs by stack lives under `stacks/<name>/`. If a script is mostly shared but needs one stack-specific tweak, split it (see `00-base.sh` + `00-stack.sh`) rather than parameterize.
- **SSH config alias prefix is `tart-<name>`.** Tart VM names stay bare (e.g. `app-a`, `test-vm`). The `tart-` prefix lives only in the generated SSH config (`tart-ssh-sync`), so `ssh -G` and `~/.ssh/config` clearly mark Tart VMs vs remote machines — you connect with `ssh tart-<name>`. `tart-up` accepts either form on input.

## Build pipeline — load-order rules

The root `stack.pkr.hcl` (one parameterized template, built with `make build STACK=<name> DISTRO=<distro>` from the repo root) defines the provisioner chain combining shared and stack-specific scripts. `DISTRO` is mandatory — there is no default. The supported distros are listed in `shared/distros`. Only two scripts have hard ordering constraints — `shared/scripts/00-base.sh` must run first and `shared/scripts/99-finalize.sh` must run last, hence the sentinel prefixes. Stack-specific `00-stack.sh` runs immediately after `shared/00-base.sh` in the same root provisioner block; it sources `shared/scripts/distro-lib.sh` and reads the stack's `packages.<family>` file to install native build deps in a distro-agnostic way.

`shared/scripts/distro-lib.sh` is the package-manager abstraction layer. It detects the package family from `/etc/os-release` (`dnf` for Fedora/RHEL, `apt` for Debian/Ubuntu) and exposes functions (`pkg_install`, `pkg_refresh`, `repo_add_mise`, `install_zellij`, etc.) that every provisioner uses. Neither shared scripts nor `00-stack.sh` call `dnf` or `apt` directly.

Native build deps for each stack live in `stacks/<name>/packages.dnf` (Fedora/RHEL names) and `stacks/<name>/packages.apt` (Debian/Ubuntu names). Adding or removing a package there takes effect on the next rebuild for the relevant distro family.

Other scripts are ordered by `stack.pkr.hcl`'s privilege grouping (root scripts share a provisioner block; user scripts share another), not by filename. The table below shows the execution order for the `php` stack.

| Exec | Script | Privilege | Why this position |
|---|---|---|---|
| 1 | `shared/scripts/00-base.sh` | root | First (`00-` sentinel). System update, core dev packages, build toolchain, zellij — all via `distro-lib.sh`. Foundation for everything else |
| 2 | `stacks/php/scripts/00-stack.sh` | root | Same root provisioner block as 00-base; reads `packages.<family>` and installs stack-specific native build deps via `pkg_install_optional`. Bundled with 00-base so the toolchain group and compile headers land in one transaction |
| 3 | `shared/scripts/mise.sh` | root | Same root block; installs mise system-wide via `repo_add_mise` (COPR on dnf, signed apt repo on apt) |
| 4 | `shared/scripts/user-config.sh` | root | Needs to `chsh` and update bash/zshenv after user-level installs are done |
| 5 | `shared/scripts/terminfo.sh` | root | Same root block as user-config; compiles the uploaded `xterm-ghostty.terminfo` into the system terminfo (`ncurses-term` omits it) |
| 6 | `stacks/php/scripts/mise-install.sh` | user | Needs `~/.config/mise/config.toml` already uploaded by Packer; installs runtimes + Composer + runs hard-gated smoke test |
| 7 | `shared/scripts/99-finalize.sh` | root | **LAST** (`99-` sentinel). Establishes final SSH posture in one atomic step: authorizes user key (consumes `/tmp/authorized_key.pub`), installs NOPASSWD sudoers, writes sshd drop-in (`00-` prefix wins over cloud-init's `50-cloud-init.conf`), locks admin password. Bundled so the window between disabling password auth and Packer disconnecting is ~milliseconds. |

If you add a new script to an existing stack, drop it in `stacks/<name>/scripts/` (no numeric prefix unless it must anchor first or last — leave those slots to the sentinels) and reference it from the root `stack.pkr.hcl` provisioner block. Ordering within a privilege block is the list order in `stack.pkr.hcl`, not the filename. A universally-useful file goes in `shared/scripts/` and is referenced once in the root template. To add a whole new stack, use `make scaffold STACK=<name>`.

## Testing changes

`packer validate` + `bash -n` catch syntax only — a real `make rebuild` is the only proof of runtime behavior. Run the fast checks first, then rebuild:

```bash
# Per-stack/distro syntax/schema check
packer validate -var stack=php -var distro=fedora stack.pkr.hcl    # ~1s; catches HCL syntax errors (run from repo root)
bash -n shared/scripts/*.sh stacks/php/scripts/*.sh

# Full rebuild (~15-20 min for PHP)
make rebuild STACK=php DISTRO=fedora

# Smoke a clone
tart clone fedora-php test-vm
ssh tart-test-vm   # auto-starts the stopped VM, then connects
# inside VM (PHP stack):
node --version && php --version && composer --version
```

The smoke test inside `stacks/php/scripts/mise-install.sh` is a hard gate — the Packer build fails if any expected PHP extension is missing. Don't bypass it.

## What NOT to do

- Don't commit Tart images (they live in `~/.tart/`; the `.gitignore` warns but doesn't enforce).
- Don't change the position of `99-finalize.sh` in any stack without thinking through SSH/password timing — it must run LAST. The build's own SSH auth (admin/admin password) must remain valid through every preceding script.
- Don't replace `pcov.enabled=1` in `stacks/php/scripts/mise-install.sh` without updating the PHP stack README's "PCOV always enabled" claim.
- Don't introduce per-host paths (`/Users/<name>/...`) into any script or config file.
- Don't add CI that tries to run `make build` — Apple Silicon nested VMs aren't available even on `macos-latest` GitHub runners. Schema validation (`packer validate`, shellcheck) is fine on GitHub-hosted macOS runners; see `.github/workflows/validate.yml`.
- Don't `playwright install chrome` in the php stack — Google doesn't ship Chrome stable for ARM64. Use `--browser=chromium` (the bundled build works). See the PHP stack README's "Known limitations".
- Don't add stack-specific or distro-specific logic to `shared/` scripts. Distro variance belongs in `distro-lib.sh`; stack variance belongs in the stack's own `scripts/` and `packages.<family>` files (see the `00-base.sh` / `00-stack.sh` / `packages.{dnf,apt}` pattern).

## Upstream sources (trust boundary)

See [`SECURITY.md`](./SECURITY.md#out-of-scope-inherited-trust) for the full inventory, including the apt-family sources introduced by the multi-distro refactor. Integrity checks this repo adds: the Composer SHA-384 check in `stacks/php/scripts/mise-install.sh`, and (apt-family only) the zellij sha256 check in `shared/scripts/distro-lib.sh`.
