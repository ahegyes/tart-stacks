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

### 2. Add VM SSH config

Some VMs need a host SSH agent forwarded into them (for in-VM git/composer against private hosts authorized only by a Mac-resident key). Others don't. List both in `~/.ssh/config` with the `RemoteForward` attached only to the VMs that need it:

```
# Common settings for every Tart VM (regardless of which stack it was cloned from).
Host app-a app-b client-site experiments
  User admin
  IdentityFile ~/.ssh/tart-vm
  SecurityKeyProvider /usr/lib/ssh-keychain.dylib   # macOS 26 native; omit for Secretive
  IdentitiesOnly yes
  UserKnownHostsFile /dev/null
  StrictHostKeyChecking no
  LogLevel ERROR

# VMs that need a host SSH agent forwarded.
Host app-a app-b
  RemoteForward /home/admin/.ssh/forwarded-agent.sock /Users/<you>/.ssh/<host-agent-socket>
```

Common `<host-agent-socket>` paths:
- 1Password: `~/.1password/agent.sock`
- Secretive: `~/Library/Containers/com.maxgoedjen.Secretive.SecretAgent/Data/socket.ssh`
- Standard `ssh-agent`: `$SSH_AUTH_SOCK` (resolve at runtime, don't hardcode)

The VM's baseline `~/.zshrc` auto-sets `SSH_AUTH_SOCK` to the forwarded socket, so git/composer use the host agent transparently.

### 3. Install the `tssh` wrapper

Tart VM IPs aren't stable across `tart delete` / `tart clone` cycles. `bin/tssh` resolves the IP via `tart ip <vm>` each invocation, while your SSH config matches by name. It uses connection multiplexing so you get exactly one biometric prompt per `tssh` call regardless of internal SSH operations. Install once; it serves every VM from every stack.

```bash
install -m 755 bin/tssh ~/.local/bin/tssh   # or copy anywhere in $PATH
```

Use: `tssh app-a`. Extra args pass through: `tssh app-a -L 8888:localhost:8888`.

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
- **`tssh` triggers Touch ID twice per session** → your `~/.ssh/config` is missing `IdentitiesOnly yes` for the VM host, so ssh tries every key in your agent. See the SSH config example in [Setup §2](#2-add-vm-ssh-config).

Stack-specific troubleshooting lives in each stack's README.

## License

MIT — see [LICENSE](./LICENSE).
