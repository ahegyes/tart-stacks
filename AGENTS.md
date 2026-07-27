# tart-stacks

Multi-distro, multi-stack collection of Packer templates that build Tart base VM images preconfigured for various language toolchains on Apple Silicon. Supports Fedora, Ubuntu, and Debian (all listed in `shared/distros`). Each stack is cloned per-project; each project VM is independent of the base.

## What's here

```
.
├── README.md  CLAUDE.md  AGENTS.md  SECURITY.md  CONTRIBUTING.md  LICENSE
├── Makefile                            # Single top-level Makefile; `make setup`/`make uninstall` install/remove the host tools; STACK=<name> DISTRO=<distro> select the cell for build/rebuild/smoke; GUI=1 DE=<de> select the optional GUI flavor
├── stack.pkr.hcl                       # the Packer template — one parameterized file (`-var stack= -var distro=` + optional `-var gui= -var de=`) builds every stack × distro [× DE]; defines the provisioner chain
├── .shellcheckrc                       # external-sources=true so shellcheck follows `# shellcheck source=` into bin/lib
├── .gitignore                          # Packer build artifacts + editor/OS noise (Tart images live in ~/.tart/, never here)
├── bin/
│   ├── lib/
│   │   ├── common.sh                   # Sourced leaf helpers, never on PATH: tart_need_cmd, tart_vm_state, tart_resolve_vm, tart_valid_vm_name, tart_ssh_has_sessiontype, tart_is_base_image, the vm-pattern pair (tart_pattern_matches/tart_resolve_pattern), tart_vm_alive (process liveness)
│   │   └── config.sh                   # Single source of truth for the ~/.config/tart-stacks/* config paths (tart_config_dir/tart_config_path; TART_* env overrides)
│   ├── tart-new                        # Creates a project VM by cloning a stack base image — `<name> <stack> <distro> [<de>]`, the optional <de> selecting a GUI flavor — with the validation `tart clone` lacks (stack exists, image built, no name collision) + `--cpu`/`--memory`/`--disk-size` pass-through; scrubs the stale host-key pin before cloning
│   ├── tart-rm                         # Deletes a project VM with the teardown `tart delete` lacks: refuses base images, stops a running VM, scrubs the host-key pin — the destroy-side mirror of tart-new
│   ├── tart-down                       # Stops a VM: resolves the `tart-` alias form, refuses base images, then `tart stop`
│   ├── tart-ssh-sync                   # Regenerates ~/.ssh/config.d/tart-vms (`tart-*` wildcard + per-VM agent blocks from ssh-agents); validates the candidate with `ssh -G` before activation — a failing one lands at tart-vms.rejected, the live file untouched
│   ├── tart-up                         # Starts a stopped VM (+ mounts + net-policy) and waits for SSH on :22, then sets the guest hostname; the hook the auto-start Match line fires on an interactive `ssh tart-<name>` (also runnable directly to pre-warm). Accepts bare or `tart-`-prefixed name. Also owns the GUI boot plane: `--gui=headless|vnc|window` (or the per-VM `gui` config), the host backing-scale probe it applies in the guest before graphical.target, and the loopback-only classifier that fails a VNC activation closed
├── script/
│   ├── setup                           # Host install run by `make setup` (symlinks the bin/ commands, zsh completion, idempotent SSH Include + placement check, forwards + mounts scaffold, closing tart-ssh-sync run); --uninstall is the inverse (keeps per-VM config)
│   ├── smoke                           # End-to-end proof of a built image, run by `make smoke`: tart-new clone → tart-up boot → guest-agent probes (`tart exec` over vsock: channel via `true`, escalation, then the guest's own name — the one channel ssh cannot stand in for) → BatchMode ssh → hostname assert → image attestation (manifest + os-release vs the requested cell, the stack's toolchain over a non-interactive ssh, sshd -T's effective hardening) → VNC surface for a GUI flavor → tart-rm teardown (SMOKE_KEEP=1 keeps the VM). Boots a real VM — local only, never CI
│   └── test                            # Runs the test suite (test/*.sh); invoked by `make test` and the CI tests job
├── completions/
│   └── _tart-new                       # Zsh completion for tart-new (stack + distro tokens, resource flags); installed by `make setup`
├── test/
│   ├── tart-new.sh                     # Characterization tests for tart-new (validation gates + clone/set wiring; mocks tart, fixture stacks/)
│   ├── tart-rm.sh                      # Characterization tests for tart-rm (lookup failure modes, base-image refusal, stop → delete ordering, known-hosts scrub; mocks tart, sandboxed HOME)
│   ├── tart-down.sh                    # Characterization tests for tart-down (prefix resolution, base-image refusal, already-stopped and failed-stop paths; mocks tart)
│   ├── tart-up.sh                      # Characterization tests for tart-up's runtime flow (resolve/prefix, base-image refusal, stopped→run w/ netpolicy + mounts, wedged-VM fail-fast, hostname; mocks tart + nc + ps)
│   ├── setup.sh                        # Characterization tests for script/setup — install surface (symlinks, Include placement, scaffolds, closing sync, idempotence) and the --uninstall inverse (ownership checks, kept config); fully sandboxed
│   ├── smoke.sh                        # Characterization tests for script/smoke (stage ordering, EXIT-trap teardown, SMOKE_KEEP, tart-new failure propagation, and the four guest-agent verdicts running ahead of ssh so a missing agent is not misreported as a bad hostname; mocks via the TART_SMOKE_BIN seam plus PATH shims for ssh and tart — no real VM)
│   ├── base.sh                         # Behavioral tests for 00-base.sh's substrate gates: the shipped region lifted out and run against a mocked systemctl (healthy passes; disabled, not-found, static, enabled-runtime and enabled-but-dead all refuse), each branch's wording — one points at the version pin and rules out re-pulling a base, the other at the unit's journal — plus a refused release and a failed agent install each stopping the build, driven through stubbed assert_release_supported / install_guest_agent so both calls stay measurable
│   ├── display-scale.sh                # Guest display-scale applier tests: exact installed template instantiated per DE against temp homes; KDE config preservation/reset, GNOME private-dbus writes, XFCE XML preservation/reset
│   ├── kde-panel.sh                    # Behavioral tests for kde-panel.sh against synthetic Plasma 5/6 templates (anchor counts, launcher gates, indentation, rerun stability)
│   ├── parsing.sh                      # Characterization tests for the tart-up + tart-ssh-sync config-line parsers
│   ├── mise-lib.sh                     # Characterization tests for mise-lib's two hard gates: smoke_gate (argv-group grammar, word-split safety, hard-fail path) and membership_gate (line-anchored `php -m` matching, incl. the warning-polluted stdout fixture)
│   ├── gui-lib.sh                      # Characterization tests for gui-lib's DE × family selectors + the shared/desktops ↔ gui_require_de lockstep
│   ├── gui.sh                          # Behavioral tests for gui.sh's X11-session gate — the shipped block lifted out and run against fixture xsessions dirs: candidate preference (plasmax11 over plasma), the Plasma-5 and Plasma-6 shapes both measured on real images, Wayland-only and empty guests refused, and the refusal naming the release and the sessions that DID materialize
│   ├── finalize.sh                     # Behavioral tests for 99-finalize.sh's anti-lockout key gate: every private-key format refused, a pubkey whose comment says PRIVATE KEY accepted, and both gates ordered ahead of the install and `passwd -l`
│   ├── makefile.sh                     # Behavioral tests for the Makefile's check-* gates (the only thing between a mistyped selector and bootstrap's destructive base re-clone); invokes the gate targets only — never build/bootstrap/smoke
│   └── distro-lib.sh                   # Characterization tests for distro-lib: _detect_family (os-release ID → dnf, ID/ID_LIKE → apt), pkg_install_optional skip recording (incl. the compat-Provides and virtual-package cases), assert_mac_enforcing, pkg_release_upgrade (commands issued and their order, the apt no-op, the idempotent and already-ahead cases, the N→N+2 refusal landing before any download, and that the post-reboot wait stays finite), assert_release_supported (past/today/future, an absent SUPPORT_END as a skip, and the refusal naming release, dates and the knob), and install_guest_agent (per-family package name, arch mapping, and the three refusals that must land before the package manager is reached: sha256 mismatch, a package the checksums file does not list, and a failed download)
├── shared/                             # Stack-agnostic — runs verbatim in every stack's build
│   ├── distros                         # Supported distro tokens, one per line; consumed by the Makefile, tart-new, the bin/ base-image guard, and the CI matrix
│   ├── desktops                        # Desktop tokens the GUI layer can bake, one per line; consumed by the Makefile (check-de), tart-new (+ its zsh completion), and the bin/ base-image guard
│   ├── gui/README.md                   # GUI-flavor image contract (engine-facing): boot modes, VNC surface, support matrix; change with gui.sh/gui-lib.sh
│   ├── scripts/
│   │   ├── 00-base.sh                  # First script (the release upgrade ahead of it is an inline block in stack.pkr.hcl, not a file). Asserts the guest's os-release ID and that its release is not past support end, installs the pinned tart-guest-agent and asserts the unit is enabled AND running, then system update + core dev pkgs + build toolchain + zellij via distro-lib.sh (root)
│   │   ├── 99-finalize.sh              # LAST. Authorize SSH key + sshd drop-in + NOPASSWD sudo + lock admin password; writes the provenance manifest incl. the gui:, support-end: and agent: lines (root)
│   │   ├── display-scale.sh            # Install template for the per-boot, per-DE guest display-scale applier; gui.sh bakes the DE/account placeholders into /usr/local/bin
│   │   ├── kde-panel.sh                # Install template for the KDE default-panel launcher pinning; gui.sh runs it for the kde DE only, standalone so its template transform is testable
│   │   ├── distro-lib.sh               # Package-manager abstraction: pkg_install/pkg_refresh/repo_add_mise/install_zellij etc. for dnf (Fedora) and apt (Debian/Ubuntu) families. Also owns the two version policies the base image would otherwise dictate — FEDORA_TARGET_RELEASE + pkg_release_upgrade (capped at dnf's N→N+2) + assert_release_supported, and TART_GUEST_AGENT_VERSION + install_guest_agent (checksum-verified before it reaches the package manager)
│   │   ├── gui.sh                      # Optional desktop layer (no-op unless -var gui=true): DE + display manager + loopback-only VNC session unit; netpolicy-neutral by design (root)
│   │   ├── gui-lib.sh                  # DE × family abstraction sourced by gui.sh: the gui_require_de/gui_require_cell gates (the latter refuses fedora × gnome — no X11 session from F43 on), package sets, DM units, X session candidates, TigerVNC session-starter paths
│   │   ├── host-keys.sh                # Installs the first-boot oneshot that regenerates a clone's SSH host keys before its sshd ever starts (root)
│   │   ├── mise-lib.sh                 # Shared helpers sourced by each stack's mise-install.sh: mise_runtime_setup + the smoke_gate/membership_gate hard gates (uploaded to /tmp; not run directly)
│   │   ├── mise.sh                     # mise install system-wide via repo_add_mise (uses COPR on dnf, signed apt repo on apt) (root)
│   │   ├── terminfo.sh                 # Compile vendored xterm-ghostty terminfo, which ncurses-term omits (root)
│   │   └── user-config.sh              # zsh default shell + bash mise activation + .zshenv PATH (incl. mise's shims) + virtiofs fstab entry and its skip-when-shareless drop-in + the /run/tart tmpfiles.d entry for forwarded agent sockets; chowns the uploaded ~/.zshrc and ~/.config (root)
│   └── files/
│       ├── xterm-ghostty.terminfo      # Ghostty terminfo source; compiled by terminfo.sh into the image
│       └── zshrc                       # In-VM shell baseline, incl. the zsh-side mise activation; uploaded to /home/admin/.zshrc
├── stacks/
│   ├── php/                            # PHP stack — per-stack content only; the template is the repo-root stack.pkr.hcl
│   │   ├── scripts/
│   │   │   ├── 00-stack.sh             # Runs immediately after shared/00-base.sh; reads packages.<family> via distro-lib.sh (root)
│   │   │   └── mise-install.sh         # Installs PHP/Node from mise.toml + PECL + Composer + smoke test (user)
│   │   ├── files/
│   │   │   └── mise.toml               # In-VM global tool versions (pinned PHP patch + Node LTS)
│   │   ├── packages.dnf                # Native build deps for dnf-family (Fedora); one or more per line, comments stripped
│   │   ├── packages.apt                # Native build deps for apt-family (Debian/Ubuntu); equivalent capabilities to packages.dnf
│   │   └── README.md                   # Stack-specific docs (what's installed, customization, troubleshooting)
│   └── jvm/                            # JVM stack — same shape; Temurin 25 + Maven/Gradle/sbt/Kotlin/scala-cli + uv + Node
├── templates/
│   └── stack/                          # Skeleton `make scaffold STACK=<name>` stamps into stacks/<name>/ (README, mise.toml, packages.{dnf,apt}, 00-stack.sh, mise-install.sh — all *.tmpl, __STACK__ substituted)
└── .github/
    ├── dependabot.yml                  # Weekly grouped github-actions bumps only (no Packer-plugin ecosystem — that pin is bounded in stack.pkr.hcl, bumped by hand)
    └── workflows/
        └── validate.yml                # packer validate + shellcheck (scripts AND scaffold templates) + the test suite, on push/PR to trunk; the packer matrix covers every stacks/* × shared/distros cell
```

## Conventions

- **`AGENTS.md` is canonical.** `CLAUDE.md` is a one-line `@AGENTS.md` import. AGENTS.md is the standard recognized by Codex, Cursor, Cline, etc.
- **Every executable shell script starts with `set -euo pipefail` — except the result-aggregating test harnesses.** `script/test` and every `test/*.sh` count failures into a verdict instead of dying on the first, so they deliberately drop `-e` and run `set -uo pipefail`. Everything else keeps all three. (Sourced libraries under `bin/lib/` set no options — they inherit the caller's.)
- **Comments explain WHY, not WHAT.** Don't restate the code; explain hidden constraints, load-order requirements, or surprising behavior.
- **Function naming: `tart_` prefix marks functions sourced from `bin/lib/`; script-local helpers stay bare.** A prefixed call (`tart_need_cmd`, `tart_config_path`) signals "defined in the lib, not this file"; a bare one (`dir_args`, `netpolicy_args`) is local. The prefix only carries that signal while it stays selective — don't add it to local helpers.
- **Naming is `tart-stacks` everywhere** for the repo. Stack directories are bare tokens (`php`, `jvm`). The Tart image name is `<distro>-<stack>` (e.g. `fedora-php`, `ubuntu-jvm`) — the distro prefix comes from the `-var distro=` build arg, not the stack dir name. A GUI flavor appends the DE token: `<distro>-<stack>-<de>` (e.g. `fedora-php-kde`). Don't introduce alternative spellings within a stack's files.
- **Host (macOS) and guest (VM) live in the same repo.** Everything under `bin/` and `script/` runs on the host, as do `make`/`packer`; everything under `shared/scripts/`, `shared/files/`, and `stacks/*/scripts/`, `stacks/*/files/` runs inside the build VM.
- **`script/` (singular) vs `scripts/` (plural) is deliberate, not a typo.** Three directories, three roles: `bin/` = user commands symlinked onto `$PATH` by `make setup` (`tart-up`, `tart-ssh-sync`, `tart-new`, `tart-rm`, `tart-down`; `make uninstall` is the inverse); `script/` = the [Scripts to Rule Them All](https://github.com/github/scripts-to-rule-them-all) namespace for host dev-tasks run via `make`, never on `$PATH` (`setup`, `smoke`, `test`); `scripts/` under `shared/` and `stacks/*/` = in-VM provisioner collections, each paired with a sibling `files/`.
- **`shared/` vs `stacks/<name>/` rule.** A file goes in `shared/` if it would be byte-identical across every plausible stack. Anything that differs by stack lives under `stacks/<name>/`. If a script is mostly shared but needs one stack-specific tweak, split it (see `00-base.sh` + `00-stack.sh`) rather than parameterize.
- **SSH config alias prefix is `tart-<name>`.** Tart VM names stay bare (e.g. `app-a`, `test-vm`). The `tart-` prefix lives only in the generated SSH config (`tart-ssh-sync`), so `ssh -G` and `~/.ssh/config` clearly mark Tart VMs vs remote machines — you connect with `ssh tart-<name>`. `tart-up` accepts either form on input.

## Build pipeline — load-order rules

The root `stack.pkr.hcl` (one parameterized template, built with `make build STACK=<name> DISTRO=<distro>` from the repo root) defines the provisioner chain combining shared and stack-specific scripts. `DISTRO` is mandatory — there is no default. The supported distros are listed in `shared/distros`. Two scripts have hard ordering constraints — `shared/scripts/00-base.sh` must run first and `shared/scripts/99-finalize.sh` must run last, hence the sentinel prefixes. One step runs even earlier and is deliberately **not** a script: an inline `provisioner "shell"` at the top of the build block calls `pkg_release_upgrade` (from `distro-lib.sh`) to lift the guest to the release the image ships as. It leads because `00-base.sh`'s first act is a full system update, which on a release about to be replaced downloads packages the upgrade then discards. It stays inline because its body is glue — every decision lives in `distro-lib.sh`, where it is tested — and it must stay **alone** in its block with `expect_disconnect = true`, since it reboots the guest and never returns. Stack-specific `00-stack.sh` runs immediately after `shared/00-base.sh` in the same root provisioner block; it sources `shared/scripts/distro-lib.sh` and reads the stack's `packages.<family>` file to install native build deps in a distro-agnostic way.

`shared/scripts/distro-lib.sh` is the package-manager abstraction layer. It detects the package family from `/etc/os-release` (`dnf` for Fedora — ID only, since that branch is Fedora-specific; `apt` for Debian/Ubuntu and their derivatives, via ID_LIKE too) and exposes functions (`pkg_install`, `pkg_refresh`, `repo_add_mise`, `install_zellij`, etc.) that every provisioner uses. Provisioners do not call `dnf` or `apt` directly; the family-abstraction libraries (`distro-lib.sh`, `gui-lib.sh`) are where those calls live.

Native build deps for each stack live in `stacks/<name>/packages.dnf` (Fedora names) and `stacks/<name>/packages.apt` (Debian/Ubuntu names). Adding or removing a package there takes effect on the next rebuild for the relevant distro family.

Other scripts are ordered by `stack.pkr.hcl`'s privilege grouping (root scripts share a provisioner block; user scripts share another), not by filename. The table below shows the execution order for the `php` stack.

| Exec | Script | Privilege | Why this position |
|---|---|---|---|
| 1 | *(inline in `stack.pkr.hcl`)* — `pkg_release_upgrade` | root | **FIRST**, in a block of its own with `expect_disconnect = true`. Not a script file: the body is `source /tmp/distro-lib.sh` + one call, and every decision lives in `distro-lib.sh` where it is tested. Lifts a dnf-family guest to `FEDORA_TARGET_RELEASE` and reboots; a no-op on apt, whose bases their publisher keeps current. Ahead of `00-base.sh` because that script's first act is a full system update, and updating a release about to be replaced downloads packages the upgrade immediately discards. Alone in its block because it never returns — `dnf offline reboot` only *schedules* the reboot, so it blocks until the guest goes down; without that, the next provisioner runs inside the system-update boot and reads the OLD release, and the build ships an image labelled as something it is not. No `pause_before` on what follows: the SSH communicator blocks until the guest is reachable again |
| 2 | `shared/scripts/00-base.sh` | root | Asserts the guest's os-release ID matches the build's `DISTRO` — the image name and manifest are both written from `DISTRO`, so a wrong base would ship mislabeled. Then `assert_release_supported`, which reads the guest's own `SUPPORT_END` and refuses a release past end of life: the target release is a hand-maintained pin, and a stale one is otherwise invisible until a repository is purged mid-build months later. Then asserts `tart-guest-agent.service` is both `enabled` (the literal state, since `is-enabled` also exits 0 for `static`/`enabled-runtime`, neither of which survives a clone's first boot) and running: `tart exec` is a host→guest vsock call served by that agent, nothing here installs it, and everything inside the build rides ssh — so a base without it builds clean, then silently leaves clones on the base image's hostname (`tart-up` warns) and hard-fails any GUI activation. Then system update, core dev packages, build toolchain, zellij — all via `distro-lib.sh` |
| 3 | `stacks/php/scripts/00-stack.sh` | root | Same root provisioner block as 00-base; reads `packages.<family>` and installs stack-specific native build deps via `pkg_install_optional`. Bundled with 00-base so the toolchain group and compile headers land in one transaction |
| 4 | `shared/scripts/mise.sh` | root | Same root block; installs mise system-wide via `repo_add_mise` (COPR on dnf, signed apt repo on apt) |
| 4b | `shared/scripts/gui.sh` | root | Own root block (needs GUI/DE as `environment_vars`); exits immediately unless `-var gui=true`. Desktop + display manager + loopback-only VNC unit per shared/gui/README.md — keep it netpolicy-neutral |
| 5 | `shared/scripts/user-config.sh` | root | Root block between the file uploads and the user-level install: needs root (`chsh`, the virtiofs `/etc/fstab` entry) and the uploaded `~/.zshrc` + `~/.config` already on disk — it chowns both to the build user |
| 6 | `shared/scripts/terminfo.sh` | root | Same root block as user-config; compiles the uploaded `xterm-ghostty.terminfo` into the system terminfo (`ncurses-term` omits it) |
| 7 | `shared/scripts/host-keys.sh` | root | Same root block; installs + enables the first-boot oneshot that regenerates a clone's SSH host keys before sshd starts (marker-gated at `/etc/ssh/.tart-keys`; the image's oneshot is the only regeneration path — nothing on the host repeats it) |
| 8 | `stacks/php/scripts/mise-install.sh` | user | Needs `~/.config/mise/config.toml` already uploaded by Packer; installs runtimes + Composer + runs hard-gated smoke test |
| 9 | `shared/scripts/99-finalize.sh` | root | **LAST** (`99-` sentinel). Establishes final SSH posture in one atomic step: authorizes user key (consumes `/tmp/authorized_key.pub`), installs NOPASSWD sudoers, writes sshd drop-in (`00-` prefix wins over cloud-init's `50-cloud-init.conf`), locks admin password. Bundled so the window between disabling password auth and Packer disconnecting is ~milliseconds. |

If you add a new script to an existing stack, drop it in `stacks/<name>/scripts/` (no numeric prefix unless it must anchor first or last — leave those slots to the sentinels) and reference it from the root `stack.pkr.hcl` provisioner block. Ordering within a privilege block is the list order in `stack.pkr.hcl`, not the filename. A universally-useful file goes in `shared/scripts/` and is referenced once in the root template. To add a whole new stack, use `make scaffold STACK=<name>`.

## Testing changes

`packer validate` + `bash -n` catch syntax only — a real `make rebuild` is the only proof of provisioner behavior, and `make smoke` is the scripted end-to-end proof of the built image. Run the fast checks first, then rebuild, then smoke:

```bash
# Per-stack/distro syntax/schema check
packer validate -var stack=php -var distro=fedora stack.pkr.hcl    # ~1s; catches HCL syntax errors (run from repo root)
bash -n shared/scripts/*.sh stacks/php/scripts/*.sh
make test                               # plain-bash test suite (test/*.sh) — mocked, no VM, what CI runs

# Full rebuild (~15-20 min for PHP)
make rebuild STACK=php DISTRO=fedora

# End-to-end proof of the built image (boots a real VM, ~1 min — local only, never CI)
make smoke STACK=php DISTRO=fedora
```

`make smoke` runs `script/smoke`: clone a throwaway VM (`tart-new smoke-vm …`), boot it (`tart-up`), probe the guest agent over `tart exec`, `ssh` in under BatchMode, assert the guest hostname, tear it down (`tart-rm`) — proving clone → boot → DHCP → the guest-agent vsock channel → sshd → key auth → provisioning → attestation in one pass. It needs the image already built and the host tools wired (`make setup`); `SMOKE_KEEP=1` keeps the VM for debugging.

The guest-agent probes are the only assertions that leave ssh. `tart exec` is a host→guest vsock RPC answered by `tart-guest-agent` **inside** the VM — installing tart on the host cannot supply it, and the agent arrives only because the base image already carried one. `bin/tart-up` routes the guest hostname (every cell) and every GUI activation through that channel, so an agent-less image passes every ssh-based check and then silently mis-names itself for a headless consumer while hard-failing a GUI one. The probes run in dependency order — channel, escalation over it, then the guest's own name — so a failure is narrowed to the causes below it instead of surfacing as a bare hostname mismatch. The channel probe runs `true` deliberately: `tart exec` propagates the guest command's own exit status, so probing with a command that can itself fail would report that as a dead channel. None of it proves the channel from inside the build — `00-base.sh` can only read the unit's configuration, since the RPC is host→guest.

The smoke test inside `stacks/php/scripts/mise-install.sh` is a hard gate — the Packer build fails if any expected PHP extension is missing. Don't bypass it.

## What NOT to do

- Don't commit Tart images (they live in `~/.tart/`; the `.gitignore` warns but doesn't enforce).
- Don't change the position of `99-finalize.sh` in any stack without thinking through SSH/password timing — it must run LAST. The build's own SSH auth (admin/admin password) must remain valid through every preceding script.
- Don't replace `pcov.enabled=1` in `stacks/php/scripts/mise-install.sh` without updating the PHP stack README's "PCOV always enabled" claim.
- Don't introduce per-host paths (`/Users/<name>/...`) into any script or config file.
- Don't add CI that tries to run `make build` — Apple Silicon nested VMs aren't available even on `macos-latest` GitHub runners. Schema validation (`packer validate`, shellcheck) is fine on GitHub-hosted macOS runners; see `.github/workflows/validate.yml`.
- Don't `playwright install chrome` in the php stack — Google doesn't ship Chrome stable for ARM64. Use `--browser=chromium` (the bundled build works). See the PHP stack README's "Known limitations".
- Don't add stack-specific or distro-specific logic to `shared/` scripts. Distro variance belongs in `distro-lib.sh`; stack variance belongs in the stack's own `scripts/` and `packages.<family>` files (see the `00-base.sh` / `00-stack.sh` / `packages.{dnf,apt}` pattern). DE × distro variance for the GUI layer belongs in `gui-lib.sh`, same rule.
- Don't let the GUI layer touch network posture: no new non-loopback listeners, no firewall, no second interface manager, no broadcast daemons. Egress confinement is applied by the host at VM start (`tart-up` netpolicy); the image must stay neutral to it — shared/gui/README.md § "Network posture" is the contract.

## Upstream sources (trust boundary)

See [`SECURITY.md`](./SECURITY.md#out-of-scope-inherited-trust) for the full inventory, including the apt-family sources introduced by the multi-distro refactor. Integrity checks this repo adds: the Composer SHA-384 check in `stacks/php/scripts/mise-install.sh`, and (apt-family only) the zellij sha256 check in `shared/scripts/distro-lib.sh`.
