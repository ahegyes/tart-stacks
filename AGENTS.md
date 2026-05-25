# tart-stacks

Multi-stack collection of Packer templates that build Fedora-on-ARM64 Tart base VM images preconfigured for various language toolchains on Apple Silicon. Each stack is cloned per-project; each project VM is independent of the base.

## What's here

```
.
├── README.md  CLAUDE.md  AGENTS.md  SECURITY.md  CONTRIBUTING.md  LICENSE
├── Makefile                            # Single top-level Makefile; `make setup` installs host tools; STACK=<name> selects stack for init/build/rebuild
├── bin/
│   ├── tart-new                        # Creates a project VM by cloning a stack base image, with the validation `tart clone` lacks (stack exists, image built, no name collision) + `--cpu`/`--memory`/`--disk-size` pass-through
│   ├── tart-ssh-sync                   # Regenerates ~/.ssh/config.d/tart-vms as a `tart-*` wildcard (per-connect IP resolution + interactive-login auto-start hook); aliases use the `tart-<name>` prefix
│   └── tart-up                         # Starts a stopped VM (+ mounts) and waits for SSH on :22; the hook the auto-start Match line fires on an interactive `ssh tart-<name>` (also runnable directly to pre-warm). Accepts bare or `tart-`-prefixed name
├── script/
│   ├── setup                           # Host install run by `make setup` (symlinks commands, zsh completion, idempotent SSH Include + catch-all check, forwards + mounts scaffold)
│   └── test                            # Runs the test suite (test/*.sh); invoked by `make test` and the CI tests job
├── completions/
│   └── _tart-new                       # Zsh completion for tart-new (stack token, arg 2); installed by `make setup`
├── test/
│   ├── tart-new.sh                     # Characterization tests for tart-new (validation gates + clone/set wiring; mocks tart, fixture stacks/)
│   └── parsing.sh                      # Characterization tests for the tart-up + tart-ssh-sync config-line parsers
├── shared/                             # Stack-agnostic — runs verbatim in every stack's build
│   ├── scripts/
│   │   ├── 00-base.sh                  # First. dnf upgrade + core dev pkgs + build toolchain + zellij (root)
│   │   ├── 99-finalize.sh              # LAST. Authorize SSH key + sshd drop-in + NOPASSWD sudo + lock admin password (root)
│   │   ├── claude.sh                   # Claude Code native installer (user)
│   │   ├── docker.sh                   # Docker CE from Docker's Fedora repo (root)
│   │   ├── mise.sh                     # mise binary install to ~/.local/bin (user)
│   │   └── user-config.sh              # zsh default shell + mise/PATH activation for bash & non-interactive shells (root)
│   └── files/
│       └── zshrc                       # In-VM shell baseline; uploaded to /home/admin/.zshrc
├── stacks/
│   └── fedora-php/                     # PHP stack
│       ├── stack.pkr.hcl               # Provisioner chain; references ../../shared + ./scripts
│       ├── scripts/
│       │   ├── 00-stack.sh             # Runs immediately after shared/00-base.sh; PHP build deps (root)
│       │   └── mise-install.sh         # Installs PHP/Node from mise.toml + PECL + Composer + smoke test (user)
│       ├── files/
│       │   └── mise.toml               # In-VM global tool versions (php = "8.5", node = "lts")
│       └── README.md                   # Stack-specific docs (what's installed, customization, troubleshooting)
└── .github/
    └── workflows/
        └── validate.yml                # packer validate + shellcheck on push/PR to trunk; matrixed over stacks
```

## Conventions

- **`AGENTS.md` is canonical.** `CLAUDE.md` is a one-line `@AGENTS.md` import. AGENTS.md is the standard recognized by Codex, Cursor, Cline, etc.
- **Every shell script starts with `set -euo pipefail`.** No exceptions.
- **Comments explain WHY, not WHAT.** Don't restate the code; explain hidden constraints, load-order requirements, or surprising behavior.
- **Naming is `tart-stacks` everywhere** for the repo; each stack is `fedora-<lang>` (matching the Tart image `output_name`). Don't introduce alternative spellings within a stack's files.
- **Host (macOS) and guest (Fedora VM) live in the same repo.** `bin/tart-up` and `bin/tart-ssh-sync` run on the host; `make`/`packer` run on the host; everything under `shared/scripts/`, `shared/files/`, and `stacks/*/scripts/`, `stacks/*/files/` runs inside the build VM.
- **`script/` (singular) vs `scripts/` (plural) is deliberate, not a typo.** Three directories, three roles: `bin/` = user commands symlinked onto `$PATH` (`tart-up`, `tart-ssh-sync`, `tart-new`); `script/` = the [Scripts to Rule Them All](https://github.com/github/scripts-to-rule-them-all) namespace for host dev-tasks run via `make`, never on `$PATH` (`setup`, `test`); `scripts/` under `shared/` and `stacks/*/` = in-VM provisioner collections, each paired with a sibling `files/`.
- **`shared/` vs `stacks/<name>/` rule.** A file goes in `shared/` if it would be byte-identical across every plausible stack. Anything that differs by stack lives under `stacks/<name>/`. If a script is mostly shared but needs one stack-specific tweak, split it (see `00-base.sh` + `00-stack.sh`) rather than parameterize.
- **SSH config alias prefix is `tart-<name>`.** Tart VM names stay bare (e.g. `app-a`, `test-vm`). The `tart-` prefix lives only in the generated SSH config (`tart-ssh-sync`), so `ssh -G` and `~/.ssh/config` clearly mark Tart VMs vs remote machines — you connect with `ssh tart-<name>`. `tart-up` accepts either form on input.

## Build pipeline — load-order rules

Each stack's `stack.pkr.hcl` defines a provisioner chain combining shared and stack-specific scripts. Only two scripts have hard ordering constraints — `shared/scripts/00-base.sh` must run first and `shared/scripts/99-finalize.sh` must run last, hence the sentinel prefixes. Stack-specific `00-stack.sh` runs immediately after `shared/00-base.sh` in the same root provisioner block (so the `dnf` cache from the upgrade is fresh and the build toolchain is already in place when stack-specific build deps install).

Other scripts are ordered by `stack.pkr.hcl`'s privilege grouping (root scripts share a provisioner block; user scripts share another), not by filename. The table below shows the execution order for the `fedora-php` stack.

| Exec | Script | Privilege | Why this position |
|---|---|---|---|
| 1 | `shared/scripts/00-base.sh` | root | First (`00-` sentinel). System update, core dev packages, build toolchain, zellij. Foundation for everything else |
| 2 | `stacks/fedora-php/scripts/00-stack.sh` | root | Same root provisioner block as 00-base; stack-specific `dnf install` (PHP build deps). Bundled with 00-base so the toolchain group and PHP-`-devel` headers land in one transaction |
| 3 | `shared/scripts/docker.sh` | root | Same root provisioner block as 00-base/00-stack (uses `dnf-plugins-core` to add Docker's repo) |
| 4 | `shared/scripts/mise.sh` | user | First user provisioner block — installs mise binary to `~/.local/bin` |
| 5 | `shared/scripts/claude.sh` | user | Same user provisioner block as `mise.sh`; no functional dependency on mise, just adjacent in the privilege-grouped chain |
| 6 | `shared/scripts/user-config.sh` | root | Needs to `chsh` and update bash/zshenv after user-level installs are done |
| 7 | `stacks/fedora-php/scripts/mise-install.sh` | user | Needs `~/.config/mise/config.toml` already uploaded by Packer; installs runtimes + Composer + runs hard-gated smoke test |
| 8 | `shared/scripts/99-finalize.sh` | root | **LAST** (`99-` sentinel). Establishes final SSH posture in one atomic step: authorizes user key (consumes `/tmp/authorized_key.pub`), installs NOPASSWD sudoers, writes sshd drop-in (`00-` prefix wins over cloud-init's `50-cloud-init.conf`), locks admin password. Bundled so the window between disabling password auth and Packer disconnecting is ~milliseconds. |

If you add a new script to an existing stack, drop it in `stacks/<name>/scripts/` (no numeric prefix unless it must anchor first or last — leave those slots to the sentinels) and reference it from the appropriate provisioner block in that stack's `stack.pkr.hcl`. Ordering within a privilege block is determined by the list order in `stack.pkr.hcl`, not by filename. If a new file is universally useful, put it in `shared/scripts/` and reference it from every stack's `stack.pkr.hcl`.

## Testing changes

```bash
# Per-stack syntax/schema check
cd stacks/fedora-php && packer validate stack.pkr.hcl    # ~1s; catches HCL syntax errors
bash -n shared/scripts/*.sh stacks/fedora-php/scripts/*.sh

# Full rebuild (~15-20 min for PHP)
make rebuild STACK=php

# Smoke a clone
tart clone fedora-php test-vm
ssh tart-test-vm   # auto-starts the stopped VM, then connects
# inside VM (PHP stack):
node --version && php --version && composer --version && docker --version
```

The smoke test inside `stacks/fedora-php/scripts/mise-install.sh` is a hard gate — the Packer build fails if any expected PHP extension is missing. Don't bypass it.

## What NOT to do

- Don't commit Tart images (they live in `~/.tart/`; the `.gitignore` warns but doesn't enforce).
- Don't change the position of `99-finalize.sh` in any stack without thinking through SSH/password timing — it must run LAST. The build's own SSH auth (admin/admin password) must remain valid through every preceding script.
- Don't replace `pcov.enabled=1` in `stacks/fedora-php/scripts/mise-install.sh` without updating the PHP stack README's "PCOV always enabled" claim.
- Don't introduce per-host paths (`/Users/<name>/...`) into any script or config file.
- Don't add CI that tries to run `make build` — Apple Silicon nested VMs aren't available even on `macos-latest` GitHub runners. Schema validation (`packer validate`, shellcheck) is fine on GitHub-hosted macOS runners; see `.github/workflows/validate.yml`.
- Don't `playwright install chrome` in the fedora-php stack — Google doesn't ship Chrome stable for ARM64. Use `--browser=chromium` (the bundled build works). See the PHP stack README's "Known limitations".
- Don't add stack-specific logic to `shared/` scripts. If something needs to differ per stack, the split happens in stack-specific files (see the `00-base.sh` / `00-stack.sh` pattern).

## Upstream sources (trust boundary)

See [`SECURITY.md`](./SECURITY.md#out-of-scope-inherited-trust) for the inventory. The Composer SHA-384 check in `stacks/fedora-php/scripts/mise-install.sh` is the only integrity verification this repo adds on top of upstream's own.
