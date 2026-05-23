# tart-stacks

Multi-stack collection of [Tart](https://tart.run/) base images for development VMs on Apple Silicon. Each stack is a Packer template that builds a Fedora-on-ARM64 VM preconfigured for a specific language toolchain. Designed as per-project clone sources — each project gets its own VM cloned from the relevant base; rebuild and destroy at will.

## Stacks

| Stack | Image name | Purpose | Details |
|---|---|---|---|
| `php` | `fedora-php` | PHP development (PHP 8.5, Composer, PECL, Node LTS) | [stacks/fedora-php/](./stacks/fedora-php/README.md) |
| `jvm` | `fedora-jvm` | JVM development (Temurin 25 LTS, Maven, Gradle, sbt, Scala CLI, Kotlin, uv, Node LTS) | [stacks/fedora-jvm/](./stacks/fedora-jvm/README.md) |

All stacks share a common base: Fedora + Docker + mise + zellij + Claude Code + standard dev utilities. Stack-specific additions (language runtimes, build deps, runtime extensions) live under each stack's directory.

## Repo layout

```
.
├── bin/
│   └── tssh                          # macOS-host SSH wrapper (Tart IP resolution + biometric multiplexing)
├── shared/
│   ├── scripts/                      # Provisioners shared across all stacks (00-base, claude, docker, mise, user-config, 99-finalize)
│   └── files/
│       └── zshrc                     # Baseline in-VM shell config
├── stacks/
│   └── fedora-php/
│       ├── stack.pkr.hcl             # References ../../shared + ./scripts in the privilege-grouped provisioner chain
│       ├── scripts/                  # Stack-specific: 00-stack.sh (build deps), mise-install.sh (runtimes + smoke test)
│       ├── files/
│       │   └── mise.toml             # Stack-specific tool versions
│       └── README.md                 # Stack-specific details (what's installed, customization, troubleshooting)
├── Makefile                          # Single top-level Makefile; commands take STACK=<name>
└── .github/workflows/validate.yml    # packer validate + shellcheck across all stacks
```

## Prerequisites

- **Apple Silicon Mac**, M1 or later. M3+ is only needed for nested virtualization (not enabled here).
- **macOS 13 Ventura or later.**
- **8 GB RAM minimum**; 16 GB+ recommended for multiple concurrent VMs.
- [Tart](https://tart.run/): `brew install cirruslabs/cli/tart`
- [Packer](https://www.packer.io/): `brew install hashicorp/tap/packer`

## Setup

### 1. Generate a Secure Enclave SSH key for Mac → VM auth

Every stack's Packer build authorizes a Secure-Enclave-backed SSH key for `admin@<vm>` and disables password auth. One key serves every VM cloned from any stack.

**macOS 26 (Tahoe) — native (recommended).** Apple ships `/usr/lib/ssh-keychain.dylib`; no third-party tools needed.

```bash
sc_auth create-ctk-identity -l "Tart VM" -k p-256-ne -t bio
ssh-keygen -w /usr/lib/ssh-keychain.dylib -K -N ""    # press Enter at PIN prompt
mv id_ecdsa_sk_rk     ~/.ssh/tart-vm
mv id_ecdsa_sk_rk.pub ~/.ssh/tart-vm.pub
chmod 600 ~/.ssh/tart-vm
chmod 644 ~/.ssh/tart-vm.pub
```

`~/.ssh/tart-vm` is *not* private key material — it's a reference handle. The actual key stays in the SE. Treat it as a normal SSH identity file (`IdentityFile ~/.ssh/tart-vm` in config). Verify with `sc_auth list-ctk-identities -t ssh`.

**macOS 13–15.** Use [Secretive](https://github.com/maxgoedjen/secretive) (`brew install --cask secretive`). Create a key with Touch ID required; save the public key to `~/.ssh/tart-vm.pub`. SSH config uses Secretive's agent socket as `IdentityAgent`.

### 2. Install the host tools

Two scripts go on your `$PATH`: `tssh` (VM SSH wrapper) and `tart-ssh-sync` (SSH config generator).

```bash
install -m 755 bin/tssh          ~/.local/bin/tssh
install -m 755 bin/tart-ssh-sync ~/.local/bin/tart-ssh-sync
```

`tssh` resolves the Tart VM IP each invocation (Tart's DHCP-assigned IPs aren't stable across clone/delete cycles) and uses SSH connection multiplexing so you get one biometric prompt per call. Accepts the VM name with or without the `tart-` prefix — `tssh app-a` and `tssh tart-app-a` both resolve. Extra args pass through: `tssh app-a -L 8888:localhost:8888`.

**Optional zsh completion** — `completions/_tssh` tab-completes VM names from `tart list`. Drop it onto your `fpath`:

```bash
ln -sf "$PWD/completions/_tssh" /opt/homebrew/share/zsh/site-functions/_tssh   # Apple Silicon
rm -f ~/.zcompdump*                                                            # force compinit rebuild
exec zsh                                                                       # pick up in current terminal
```

`tssh te<TAB>` → `tssh test-vm`. Subsequent args delegate to ssh's built-in completer (so `-L`, `-R`, `-o`, etc. complete normally).

### 3. Generate SSH config

`tart-ssh-sync` regenerates `~/.ssh/config.d/tart-vms` from `tart list` whenever you create or destroy a VM. Generated host aliases use the `tart-<name>` prefix so `ssh -G` output makes it obvious it's a Tart VM, not a remote machine.

One-time host setup — add this to the **top** of `~/.ssh/config` (before any `Host *` block, so specific Tart settings beat the catch-all):

```
Include ~/.ssh/config.d/tart-vms
```

Then run the generator any time `tart list` changes:

```bash
tart-ssh-sync             # rewrite ~/.ssh/config.d/tart-vms
tart-ssh-sync --dry-run   # print what would be written without touching disk
```

What the script emits as universal defaults (apply to every Tart VM):

- **Common block**: user, identity file, host-key handling, multiplexing.
- **Agent socket forward**: `/home/admin/.ssh/forwarded-agent.sock` ← your host SSH agent. The in-VM `~/.zshrc` auto-sets `SSH_AUTH_SOCK` to the forwarded socket, so `git`/`ssh`/`composer` inside the VM transparently use the host agent. **By default the generator reads `$SSH_AUTH_SOCK`** — whatever agent your shell is wired to. Override with `TART_AGENT_SOCKET=/path/to/socket` (1Password's `~/.1password/agent.sock`, Secretive's container socket, etc.) when you want a specific agent regardless of shell state.

What you opt into per-VM (your personal forwards, never committed): `~/.config/tart-stacks/forwards`. Each non-blank, non-comment line:

```
<vm-pattern> RemoteForward <args>
```

`<vm-pattern>` is `*` (all dev VMs), a single bare name, or a comma-separated list. Names that don't exist in `tart list` are silently dropped — you can keep entries for VMs that come and go.

Example `~/.config/tart-stacks/forwards`:

```
* RemoteForward 27123 127.0.0.1:27123              # Obsidian Personal REST API
* RemoteForward 27125 127.0.0.1:27125              # Obsidian Work REST API
work-a,work-b RemoteForward 8080 127.0.0.1:8080    # host SOCKS proxy for specific VMs
```

Re-run `tart-ssh-sync` after editing this file.

### 4. Build a stack image

```bash
make init STACK=php        # one-time per stack: installs the Tart Packer plugin
make build STACK=php       # bootstrap + build (~15-20 min for PHP — compiles from source)
tart list                  # confirm fedora-php is present
```

`make build` chains `make bootstrap` first (pulls `ghcr.io/cirruslabs/fedora:latest`, refreshes the local `fedora-base` image), then runs Packer through the stack's provisioner chain.

**Build auth.** Cirrus's `admin/admin` for provisioning. Each stack's `shared/scripts/99-finalize.sh` runs LAST and atomically establishes the final access posture: authorizes your `tart-vm.pub`, writes `00-vm-hardening.conf` disabling password auth (the `00-` prefix is load-bearing — it wins over cloud-init's `50-cloud-init.conf` which re-enables password auth), installs NOPASSWD sudoers, and locks the admin password (`passwd -l`). Bundling these means Packer's password-authed session stays valid through every preceding script and there's no fragility window between disabling password auth and disconnect.

**Pin a Fedora version:** `FEDORA_TAG=42 make bootstrap`. Cirrus publishes `latest`, `42`, `39`, `38`; only `latest` and `42` work here (39 and 38 are pre-dnf5 — they break `docker.sh`).

## Daily use

### Clone for a project

```bash
tart clone fedora-php app-a
tart run app-a --no-graphics &
tssh app-a
```

Substitute `fedora-php` for whichever stack image matches your project. Each clone is a copy-on-write snapshot; rebuilds of a base don't affect existing clones.

**Per-clone tweaks** (no rebuild required):

- Share a host directory into the VM: append `--dir=project:~/code/myproject` to `tart run`. Tart exposes the dir via virtiofs; see `tart run --help` for the in-VM path convention.
- Adjust resources: `tart set app-a --memory 16384 --cpu 8 --disk-size 100`. Takes effect on the next `tart run`.

### Persistence + multiplexing (zellij)

Every stack ships with zellij so work in the VM survives SSH disconnects (laptop sleep, network blip, network switch). Per host terminal tab/session, attach to a named zellij session — independent state per tab, all survive disconnect:

```bash
tssh app-a       # in tab 1
za term          # attach to (or create) "term" session — terminal work

tssh app-a       # in tab 2
za docker        # attach to (or create) "docker" session — independent
```

Detach with `Ctrl-q` then `d`. Reattach later from any new `tssh` with `za <name>`. Forgot what sessions exist? Run `za` with no args to list them.

**Multi-tab gotcha:** running plain `zellij` (without a name) in two host tabs attaches both to the same default session — both tabs mirror each other, useless for parallel work. Always use named sessions (`za <name>`) when working across tabs.

### Iterate a stack base

```bash
# edit a file under shared/ or stacks/<name>/
make rebuild STACK=php         # force-overwrites the existing fedora-php image
```

New project VMs cloned after the rebuild get the updated base. Existing project VMs are unaffected — they're already independent clones.

### Destroy and recreate a project VM

```bash
tart stop app-a && tart delete app-a
tart clone fedora-php app-a
# fresh, identical, ready in seconds (Tart uses copy-on-write).
```

### On-demand credential loading

For tokens you'd otherwise stash in `~/.zshrc` (GitHub, AWS, Stripe, etc.), define a `with-*` wrapper that pulls the secret from your host store and exports it for one command only — tokens never live in the shell env between calls. Drop this in `~/.zshrc` **inside a project VM** (not in `shared/files/zshrc`, which ships to every clone):

```bash
with-gh() {
  local token
  token=$(pass-cli read GITHUB_TOKEN/token 2>/dev/null) || {
    echo "with-gh: failed to read GITHUB_TOKEN from secret store" >&2
    return 1
  }
  GITHUB_TOKEN="$token" "$@"
}
```

One function per credential (`with-aws`, `with-stripe`, etc.); adjust `pass-cli read` to whichever secret-store CLI you use.

## Adding a new stack

1. `mkdir -p stacks/fedora-<name>/{scripts,files}`
2. Create `stacks/fedora-<name>/stack.pkr.hcl` — copy `stacks/fedora-php/stack.pkr.hcl` as a starting point; set `output_name`, adjust the provisioner chain to reference your stack's scripts.
3. Add `stacks/fedora-<name>/scripts/00-stack.sh` for any stack-specific `dnf install`. Runs immediately after `shared/scripts/00-base.sh` in the same root provisioner block.
4. Add `stacks/fedora-<name>/scripts/mise-install.sh` (or equivalent) to install the language runtime + tooling + smoke test.
5. Add `stacks/fedora-<name>/files/mise.toml` for tool versions.
6. Add `stacks/fedora-<name>/README.md` with stack-specific details.
7. `make init STACK=<name> && make build STACK=<name>`.
8. Add the stack to the table at the top of this README and to the CI matrix in `.github/workflows/validate.yml`.

## Troubleshooting

- **`packer init` fails with "no plugins for github.com/cirruslabs/tart"** → upgrade Packer (`brew upgrade hashicorp/tap/packer`); the tart plugin requires Packer 1.7+.
- **Build hangs at "Waiting for SSH"** → usually a Tart networking hiccup. Open a second terminal: `tart ip fedora-base`. If blank, the VM didn't get DHCP — `tart stop fedora-base; tart delete fedora-base; make bootstrap` to start over.
- **`tssh` triggers Touch ID twice per session** → `~/.ssh/config.d/tart-vms` isn't being matched (missing `Include` line, or it's below `Host *`), so ssh falls back to defaults and tries every key in your agent. See [Setup §3](#3-generate-ssh-config).

Stack-specific troubleshooting lives in each stack's README.

## License

MIT — see [LICENSE](./LICENSE).
