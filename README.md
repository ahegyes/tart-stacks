# tart-stacks

[![validate](https://github.com/ahegyes/tart-stacks/actions/workflows/validate.yml/badge.svg)](https://github.com/ahegyes/tart-stacks/actions/workflows/validate.yml)

Multi-distro, multi-stack collection of [Tart](https://tart.run/) base images for development VMs on Apple Silicon. A single parameterized Packer template builds any stack on any supported distro (Fedora, Ubuntu, Debian — see `shared/linux/os`), producing a `<distro>-<stack>` image. Any stack can additionally be built as a **GUI flavor** (`GUI=1 DE=kde|gnome|xfce`) — a desktop environment + loopback-only VNC layer baked on top, producing `<distro>-<stack>-<de>`; the boot contract lives in [shared/linux/gui/README.md](./shared/linux/gui/README.md). Designed as per-project clone sources — each project gets its own VM cloned from the relevant base; rebuild and destroy at will.

## Stacks

| Stack | Image name | Purpose | Details |
|---|---|---|---|
| `php` | `<distro>-php` | PHP development (PHP 8.5, Composer, PECL, Node LTS) | [stacks/php/](./stacks/php/README.md) |
| `jvm` | `<distro>-jvm` | JVM development (Temurin 25 LTS, Maven, Gradle, sbt, Scala CLI, Kotlin, uv, Node LTS) | [stacks/jvm/](./stacks/jvm/README.md) |

`<distro>` is the distribution token (e.g. `fedora`). `shared/linux/os` lists the supported values.

All stacks share a common base: mise + zellij + standard dev utilities, wired through a package-family abstraction layer (`shared/linux/scripts/family-lib.sh`) that handles dnf (Fedora) and apt (Debian/Ubuntu) package families. Stack-specific additions (language runtimes, build deps, runtime extensions) live under each stack's directory. The base stays a clean runtime substrate — layer project- or org-specific tooling onto clones rather than baking it into the image.

## Repo layout

```
.
├── bin/          host commands, symlinked onto PATH by `make setup`
├── script/       host dev-tasks run via `make` (setup, smoke, test)
├── shared/       stack-agnostic in-VM provisioning + the GUI layer
├── stacks/       one directory per stack (php, jvm): packages + install scripts
├── templates/    skeleton `make scaffold` stamps into a new stack
└── test/         the mocked suite `make test` runs
```

[`AGENTS.md`](./AGENTS.md) carries the annotated version — every file with a
one-line description of what it is. It is the single map; this list is only an
orientation.

`script/` (singular) is the [Scripts to Rule Them All](https://github.com/github/scripts-to-rule-them-all) namespace for host dev-tasks run via `make`; `scripts/` (plural, under `shared/` and `stacks/*/`) are in-VM provisioner collections. Different roles, hence the different names.

## Prerequisites

- **Apple Silicon Mac**, M1 or later. M3+ is only needed for nested virtualization (not enabled here).
- **macOS 26 Tahoe or later.** The floor is set by OpenSSH: the generated SSH config's auto-start hook uses `Match sessiontype`, which needs **OpenSSH 10.0+** and which older ssh rejects as a fatal parse error — in an Included file, that takes down every `ssh` on the host. macOS 26 is the first release to ship it (26.5 has 10.2). `tart-ssh-sync` probes for the keyword and, failing it, writes nothing at all: on an older macOS you get no `tart-<name>` alias, no identity pinning and no connect-time IP resolution, so you reach a VM as `ssh admin@$(tart ip <name>)`. Building and running images works; the SSH ergonomics are what you lose.
- **8 GB RAM minimum**; 16 GB+ recommended for multiple concurrent VMs.
- [Tart](https://tart.run/): `brew install openai/tools/tart` — Tart, softnet and the guest agent moved to the `openai` org; the older `cirruslabs/cli` tap is frozen and current Homebrew refuses to load formulae from it. Distro base images are still published under `ghcr.io/cirruslabs`.
- [Packer](https://www.packer.io/): `brew install hashicorp/tap/packer`
- [jq](https://jqlang.org/) — the host commands (`tart-new`, `tart-up`, `tart-rm`, `tart-down`) parse `tart list --format json` with it. macOS 15+ ships one at `/usr/bin/jq`, so this is normally already satisfied; `brew install jq` if `jq --version` fails.

## Setup

### 1. Create a Secure Enclave SSH key for Mac → VM auth

Every stack's Packer build authorizes a Secure-Enclave-backed SSH key for `admin@<vm>` and disables password auth — one key serves every VM cloned from any stack, and the private key never leaves the Enclave. Whether that key prompts for Touch ID on use is your call (see below).

Use [Secretive](https://github.com/maxgoedjen/secretive):

```bash
brew install --cask secretive
```

Open Secretive, create a key (**+**), and name it `Tart VM`. **Choose its authentication mode deliberately — that's a threat-model call, covered just below.** Then point `~/.ssh/tart-vm.pub` at it. Secretive files keys under opaque hash names, identified only by their comment — the name you gave, with spaces rendered as hyphens, so `Tart VM` becomes the `Tart-VM` the grep below matches. **Symlink** rather than copy, so Secretive stays the single source of truth and `~/.ssh` holds no duplicate. Confirm exactly one key matches, then link it:

```bash
grep -l 'Tart-VM' ~/Library/Containers/com.maxgoedjen.Secretive.SecretAgent/Data/PublicKeys/*.pub   # expect ONE file
ln -sf "$(grep -l 'Tart-VM' ~/Library/Containers/com.maxgoedjen.Secretive.SecretAgent/Data/PublicKeys/*.pub)" ~/.ssh/tart-vm.pub
```

**Using a different agent?** Secretive is a recommendation, not a requirement. `tart-ssh-sync` writes whatever socket `TART_IDENTITY_AGENT` names into the generated config — set it before running `make setup` (which ends with a sync) or before any later `tart-ssh-sync`:

```sh
TART_IDENTITY_AGENT=~/.1password/agent.sock make setup   # 1Password
TART_IDENTITY_AGENT='$SSH_AUTH_SOCK' make setup          # whatever agent your shell already has
```

The literal string `$SSH_AUTH_SOCK` is meaningful to OpenSSH's `IdentityAgent` — quote it so your shell passes it through. Either way, point `~/.ssh/tart-vm.pub` at the public half of the key you want VMs to trust; the rest of this section is Secretive-specific detail.

If the first command lists **more than one** file, you have duplicate-named keys — tell them apart with `ssh-keygen -lf <file>` and symlink the specific one by hand. (An extra key in Secretive is harmless: `IdentitiesOnly yes` in the generated config means SSH only ever offers the pinned `~/.ssh/tart-vm.pub`.)

**Touch ID, or not?** Secretive asks, at creation, whether the key requires authentication. Either way the private key stays non-extractable in the Secure Enclave — the modes differ only in whether *using* it prompts:

- **Require authentication** — every VM login (and every `git` / `rsync` / Gateway / VS Code reconnect) prompts for Touch ID.
- **No authentication while unlocked** — no prompt while the Mac is unlocked; the key still refuses to sign when the Mac is locked.

This key only authenticates the **Mac → VM hop** to a local, disposable dev VM. Credentials that reach real infrastructure are *forwarded into* the VM by a separate agent and gated independently (see [SSH config sync](#3-ssh-config-sync)), so the login key's blast radius is small. Choose by usage and threat model:

- **No-auth-while-unlocked** suits frequent interactive use on a Mac only you use: you accept that code already running as you on an *unlocked* Mac can reach the VM too (it largely can anyway), in exchange for zero prompts.
- **Require Touch ID** suits a stricter posture — a shared or higher-risk Mac, or a VM that itself holds something sensitive — where asserting presence on each login is worth a prompt.

Two caveats: **(1)** "no auth while unlocked" is *no prompt*, not *no protection* — the key is Enclave-bound and unusable while the Mac is locked, and it changes nothing about how your forwarded keys are gated. **(2)** Secretive fixes the mode **at key creation**; you can't toggle it later. Switching means creating a *new* key and re-authorizing it everywhere it's baked — rebuild the stack images (they bake `~/.ssh/tart-vm.pub`) and update `~/.ssh/authorized_keys` on any running VMs — so pick deliberately now.

`tart-ssh-sync` wires every VM to authenticate through Secretive's agent socket (`IdentityAgent`) with `IdentityFile ~/.ssh/tart-vm.pub` pinned under `IdentitiesOnly yes` — so SSH offers exactly this one key (and, in require-authentication mode, one Touch ID prompt per connection), even when Secretive holds other keys.

### 2. Install the host tools

```bash
make setup
```

Idempotent — run once, re-run anytime. It symlinks `tart-up`, `tart-ssh-sync`, `tart-new`, `tart-rm` and `tart-down` into `~/.local/bin`, installs the zsh completion for `tart-new` (detecting your Homebrew prefix), adds `Include ~/.ssh/config.d/tart-vms` to the top of `~/.ssh/config` (and warns, without editing, if an existing one sits below the first `Host`/`Match` line, where ssh either skips it or lets that block outrank it), scaffolds `~/.config/tart-stacks/forwards` and `~/.config/tart-stacks/mounts`, and finishes by running `tart-ssh-sync` to generate `~/.ssh/config.d/tart-vms` (when Tart is installed — without it, setup warns and you run `tart-ssh-sync` yourself once Tart is in). Reload completion once afterward: `rm -f ~/.zcompdump* && exec zsh`.

Stopping a VM is `tart-down <name>` — `tart stop` with the same gates as the rest: it accepts the bare or `tart-`-prefixed name and refuses stack base images. Several settings here (mounts, net-policy, gui mode) apply at boot, so `tart-down <name>` followed by a fresh `ssh tart-<name>` is how you pick up a change to them.

`make uninstall` is the inverse: it removes only what verifiably points into this repo (the command symlinks, the completion, the exact Include block setup wrote, the generated config), keeps every per-VM config file (`forwards`, `mounts`, `gui`, `ssh-agents`, `netpolicy` — they carry your opt-ins).

There's no SSH wrapper to remember — you connect with plain **`ssh tart-<name>`**. The generated config (next section) resolves the VM's current IP at connect time (Tart's DHCP-assigned IPs aren't stable across clone/delete cycles) and, on an *interactive* login only, auto-starts the VM if it's stopped. So `ssh tart-app-a` to a powered-off VM just works: it boots, waits for SSH, and drops you in — with a Touch ID prompt only if the key is in require-authentication mode. To pre-warm a VM without opening a shell, run `tart-up <name>` directly.

> Wiring it by hand instead? `make setup` is a thin wrapper over [`script/setup`](./script/setup) — read it for the exact steps.

### 3. SSH config sync

`make setup` already added the `Include ~/.ssh/config.d/tart-vms` line to `~/.ssh/config` and ran `tart-ssh-sync` to generate that file: a **`tart-*` wildcard** block carrying user, identity, host-key handling, a `ProxyCommand` that resolves the VM's current IP at connect time, and an interactive-login auto-start hook — plus one per-VM block for each entry in `~/.config/tart-stacks/ssh-agents` that forwards its SSH agent(s). So plain `ssh tart-app-a`, JetBrains Gateway, VS Code Remote-SSH, `rsync`, and `git` all reach a VM by name.

Because the connection settings live in the wildcard, **a freshly cloned VM connects immediately** — `ssh tart-<newname>` needs no per-VM registration. The first sync is `make setup`'s job; re-run `tart-ssh-sync` by hand only to:

- pick up edits to `~/.config/tart-stacks/ssh-agents` (not created by `make setup` — the tooling that manages your VMs writes it, or you create it by hand) — per-VM agent forwarding (see the **Agent forward** grammar below). A VM needs an entry here for in-VM git/ssh to use a forwarded agent;
- pick up edits to `~/.config/tart-stacks/forwards` (below).

```bash
tart-ssh-sync             # rewrite ~/.ssh/config.d/tart-vms
tart-ssh-sync --dry-run   # print what would be written, without touching disk
```

Activation is gated: the generated config must pass a full `ssh -G` parse before it replaces the live file — one malformed line in an Included file would break every `ssh`/`scp`/`git` on the host. A failing candidate is kept at `~/.ssh/config.d/tart-vms.rejected` for inspection; the live file stays untouched.

What the script emits as universal defaults (apply to every Tart VM via `Host tart-*`):

- **Common block**: user, identity (Secretive agent socket + the pinned `~/.ssh/tart-vm.pub`), host-key handling, and a `ProxyCommand` that resolves each VM's current IP at connect time (any SSH client reaches a *running* VM by name).
- **Auto-start hook**: a `Match host tart-* sessiontype shell exec …` line that runs `tart-up` — an *interactive* `ssh tart-<name>` from a terminal to a stopped VM starts it (and waits for SSH). Two gates keep everything else out: `sessiontype shell` means `git`/`rsync` (a remote command), `sftp` (a subsystem), and `ssh -N` (transport-only) **never** boot a VM, and a controlling-terminal check means terminal-less contexts (IDE/GUI config scans, `ssh -G` probes from tooling, automation) don't either. Need a VM up from a context with no terminal? Pre-warm it with `tart-up <name>`.
- **Agent forward**: per-VM agent forwarding, declared in `~/.config/tart-stacks/ssh-agents`. Each non-blank, non-comment line is exactly three whitespace-separated tokens:

  ```
  <vm> <agent> <host-socket>
  ```

  `<vm>` and `<agent>` are bare names matching `[A-Za-z0-9][A-Za-z0-9_-]*` — bare names *only*, deliberately no `*` or comma-list patterns: agent forwarding is fail-closed per VM, and a pattern token would grant an agent to VMs never listed. A line that violates any of this is skipped with a warning, never half-emitted (any producer may write the file; the grammar above is the contract, and `tart-ssh-sync` enforces it).

  Each VM listed forwards its host SSH agent via OpenSSH `ForwardAgent`, so sshd exports `SSH_AUTH_SOCK` in *every* in-VM session of that VM — interactive shells and non-interactive `ssh tart-<name> <cmd>` (git, rsync, provisioning) alike — and `git`/`ssh`/`composer` transparently use it. The first line for a VM is its primary `ForwardAgent`; any extra agents become `RemoteForward`s at `/run/tart/agent-<name>.sock` for per-host routing. Point a host-socket at 1Password's `~/.1password/agent.sock`, Secretive's container socket, or any relay. To *sign* commits in-VM, the agent signs but git also needs the pubkey *file* — mount a read-only pubkey dir and set `user.signingKey` to it (see [Per-VM directory mounts](#4-per-vm-directory-mounts)).

What you opt into per-VM (your personal forwards, never committed): `~/.config/tart-stacks/forwards`. Each non-blank, non-comment line:

```
<vm-pattern> RemoteForward <args>
```

`<vm-pattern>` is `*` (all dev VMs), a single bare name, or a comma-separated list. The directive must be literally `RemoteForward` and must carry at least one argument — any other directive, or a bare `RemoteForward` with nothing after it, is skipped with a warning (an argument-less one would be an OpenSSH fatal that takes the whole generated file down). A forward for a VM that doesn't exist yet is harmless — it stays inert until that VM is cloned.

Example `~/.config/tart-stacks/forwards`:

```
* RemoteForward 27123 127.0.0.1:27123              # Obsidian Personal REST API
* RemoteForward 27125 127.0.0.1:27125              # Obsidian Work REST API
work-a,work-b RemoteForward 8080 127.0.0.1:8080    # host SOCKS proxy for specific VMs
```

Re-run `tart-ssh-sync` after editing this file.

### 4. Per-VM directory mounts

Share host directories into VMs by listing them in `~/.config/tart-stacks/mounts` (scaffolded by `make setup`). When an interactive `ssh tart-<name>` **starts** a stopped VM (via `tart-up`), it attaches every mount whose pattern selects that VM as a `tart run --dir` share. Because `--dir` attaches at boot, a mount applies only on that start — a VM that's already running won't gain one until a stop + start (`tart-up` warns when it skips configured mounts).

Each non-blank, non-comment line:

```
<vm-pattern> [<name>=]<host-path>[:ro]
```

`<vm-pattern>` is `*` (all dev VMs), a single bare name, or a comma-separated list — the same matching as the forwards file. `<host-path>` is an absolute host path; append `:ro` to mount it read-only. The share surfaces in the guest at `/mnt/shared/<name>`, where `<name>` defaults to the path's basename; prefix `<name>=` to rename it — needed when two shares would otherwise collide on basename (e.g. `~/src/app` and `~/.config/app`). Every `--dir` share lives under the single `com.apple.virtio-fs.automount` virtiofs device.

Example `~/.config/tart-stacks/mounts`:

```
* /Users/me/src/dotfiles:ro          # read-only dotfiles in every VM
build-vm /Users/me/code/project      # writable project dir, one VM
build-vm cfg=/Users/me/.config/app   # renamed share -> /mnt/shared/cfg
```

Provisioning adds the mount point, an `/etc/fstab` entry, and a unit condition that skips the mount when the host attached no share — `nofail` alone would leave a shareless VM reporting `degraded` with a permanently failed unit. An unreadable `mounts` file makes `tart-up` refuse to start the VM rather than start it without its shares (the same fail-closed rule as the net-policy below). The equivalent by hand:

```bash
sudo mkdir -p /mnt/shared
sudo mount -t virtiofs com.apple.virtio-fs.automount /mnt/shared
```

### 5. Network egress policy (optional)

`~/.config/tart-stacks/netpolicy` confines every VM's outbound network. `tart-up` reads it and passes its contents as Tart `--net-*` flags when it **starts** a VM, so it applies at VM start (a running VM needs a stop + start to pick up changes). An absent or empty file means default Tart NAT — unfiltered.

Each non-blank, non-comment line contributes whitespace-separated tokens (`#` comments and blanks ignored), and **every token must be a `--net-*` flag** (any producer may write the file; that grammar is the contract, and `tart-up` enforces it). A flag's value rides the `=` form — `--net-bridged=en0`, never `--net-bridged en0`, even though Tart's own CLI accepts the space form. Any other token makes `tart-up` refuse to start the VM, naming the file, line, and token: this is security config, so it fails closed — starting under a partial policy would be worse than not starting at all. Example — softnet egress confined to the host gateway:

```
--net-softnet
--net-softnet-allow=@host
```

See Tart's `--net-*` documentation for the flag vocabulary.

### 6. Build a stack image

```bash
make init                             # one-time: installs the Tart Packer plugin
make build STACK=php DISTRO=fedora    # bootstrap + build (~15-20 min for PHP — compiles from source)
tart list                             # confirm fedora-php is present
```

`make build` chains `make bootstrap` first (pulls `ghcr.io/cirruslabs/<distro>:latest`, refreshes the local `<distro>-base` image), then runs Packer through the stack's provisioner chain.

**The Fedora images are not built on the release the base is published at.** Upstream pins its Fedora image to a release that is already past end of life and advances it by hand, so re-pulling the base never moves it. The first provisioner in `stack.pkr.hcl` therefore calls `pkg_release_upgrade` (from `shared/linux/scripts/family-lib.sh`), lifting the guest to `FEDORA_TARGET_RELEASE` and rebooting before anything is installed — about two extra minutes on a Fedora build, and nothing at all on Debian or Ubuntu, whose bases their publisher keeps current. `00-base.sh` then refuses any release past its own `SUPPORT_END`, so letting that pin go stale fails the build instead of quietly shipping an unpatched image. Raising it is a one-line edit, capped by dnf's two-release upgrade limit; `pkg_release_upgrade` refuses a wider jump and names the highest target you can reach in one hop.

**Build auth.** Cirrus's `admin/admin` for provisioning. Each stack's `shared/linux/scripts/99-finalize.sh` runs LAST and atomically establishes the final access posture: authorizes your `tart-vm.pub`, writes `00-vm-hardening.conf` disabling password auth (the `00-` prefix is load-bearing — it wins over cloud-init's `50-cloud-init.conf` which re-enables password auth), installs NOPASSWD sudoers, and locks the admin password (`passwd -l`). Bundling these means Packer's password-authed session stays valid through every preceding script and there's no fragility window between disabling password auth and disconnect.

**Pin a base image tag:** `IMAGE_TAG=42 make bootstrap DISTRO=fedora`. Cirrus publishes `latest` and version-pinned tags per distro.

**GUI flavor.** Add `GUI=1` (and optionally `DE=kde|gnome|xfce`, default `kde` — see `shared/linux/desktops`) to bake a desktop environment, display manager, and a loopback-only VNC server on top of the same stack:

```bash
make build STACK=php DISTRO=fedora GUI=1 DE=kde    # builds fedora-php-kde (~+10 min, ~+2 GB)
```

The image still boots headless by default; a boot opts into the desktop by starting `tart-stacks-vnc.service` (VNC on `127.0.0.1:5901`, reach it through `ssh -L 5901:127.0.0.1:5901 tart-<vm>`) or isolating `graphical.target` — the latter shows a window only when the VM was launched with one (plain `tart run <vm>`, or `tart-up` and the `ssh` auto-start when the VM's entry in the gui config selects `window` — they boot `--no-graphics` otherwise, and VNC works either way). Autologin is baked (the image locks the account password, so a greeter would be a dead end), and the desktop deliberately changes nothing about the network posture. The full contract — boot modes, VNC surface, support matrix (every cell but fedora × gnome, which Fedora's Wayland-only GNOME rules out) — is [shared/linux/gui/README.md](./shared/linux/gui/README.md).

## Daily use

### Clone for a project

```bash
tart-new app-a php fedora       # validate stack + image, clone (resources optional)
tart-new gui-a php fedora kde   # same, from the GUI flavor fedora-php-kde
ssh tart-app-a                  # auto-starts the stopped clone and connects
```

`tart-new <name> <stack> <distro> [<de>]` guards `tart clone`: it fails with a clear message if the stack doesn't exist or its image isn't built (offering to build it), refuses a name in the reserved base-image namespace (`<distro>-base`, `<distro>-<stack>`, `<distro>-<stack>-<de>` — those are clone sources, and the rest of the toolchain declines to touch them), refuses to clobber an existing VM, and folds in resources (`--cpu`/`--memory`/`--disk-size`) and the virtual display geometry (`--display`) that would otherwise be a separate `tart set`. `<stack>` is the short token, as in `make build STACK=php DISTRO=fedora`; the optional `<de>` selects a GUI flavor image, as in `GUI=1 DE=kde` (see [shared/linux/gui/README.md](./shared/linux/gui/README.md)); the raw equivalent is `tart clone fedora-php app-a`. Each clone is a copy-on-write snapshot; rebuilds of a base don't affect existing clones. The `tart-*` wildcard config makes the new clone reachable as `ssh tart-app-a` immediately — no per-VM `tart-ssh-sync` step.

**Per-clone tweaks** (no rebuild required):

- Share a host directory into the VM: list it in `~/.config/tart-stacks/mounts` (see [Per-VM directory mounts](#4-per-vm-directory-mounts)) for a persistent opt-in, or append `--dir=project:/Users/me/code/myproject` to `tart run` for a one-off. Tart exposes the dir via virtiofs at `/mnt/shared/<name>`.
- Adjust resources: `tart set app-a --memory 16384 --cpu 8 --disk-size 100`. Takes effect on the next `tart run`.

### Persistent terminal sessions (zellij)

Every stack ships [zellij](https://zellij.dev/), a terminal multiplexer (think tmux or screen): your shells, running processes, and scrollback live *inside the VM*, so they survive an SSH disconnect — laptop sleep, network blip, Wi-Fi switch. That's distinct from SSH itself: a dropped `ssh tart-<name>` loses only the connection, and zellij keeps the work alive for the next one.

Per host terminal tab, attach to a named session — independent state per tab, all surviving disconnect. The in-VM `za` helper wraps `zellij attach --create`:

```bash
ssh tart-app-a   # in tab 1
za term          # attach to (or create) "term" session — terminal work

ssh tart-app-a   # in tab 2
za logs          # attach to (or create) "logs" session — independent
```

Detach (leaving the session running) with `Ctrl-o` then `d`; reconnect later from any new `ssh tart-<name>` with `za <name>`. Run `za` with no args to list sessions. Don't use `Ctrl-q` to leave — it quits zellij and ends the session.

**Name your sessions.** Plain `zellij` starts a *new* session each time, under a generated name (`glowing-donkey`, …), so a second tab does get its own state — but after a disconnect nothing points you back at the one you were in, and `zellij list-sessions` is all you have. `za <name>` attaches to that name or creates it, which is what makes a tab's work findable again.

### Iterate a stack base

```bash
# edit a file under shared/ or stacks/<name>/
make rebuild STACK=php DISTRO=fedora    # force-overwrites the existing fedora-php image
```

New project VMs cloned after the rebuild get the updated base. Existing project VMs are unaffected — they're already independent clones.

### Destroy and recreate a project VM

```bash
tart-rm app-a
tart-new app-a php fedora
# fresh, identical, ready in seconds (Tart uses copy-on-write).
```

`tart-rm <name>` is the teardown mirror of `tart-new`'s guarded create. Under the hood it's a `tart stop && tart delete` with the gates that command pair lacks: it accepts the bare or `tart-`-prefixed name, refuses stack base images (losing one costs a 15-20 min rebuild), stops a running VM, deletes it, and scrubs the VM's host-key pin from `~/.ssh/known_hosts.tart` so a future VM reusing the name re-pins fresh instead of tripping `accept-new`.

### When a VM crashes

A `tart run` process can die abruptly — for example when Apple's
Virtualization.framework traps on a guest-vsock connect and aborts the whole
process. When it does, every SSH session to that VM drops at once (surfacing as
a "broken pipe" the next time you type), any host service the VM reached over a
forwarded port goes with it, and Tart can leave the VM wedged in a "running"
state that a plain restart refuses until `tart stop` clears it.

This is an upstream bug, not something tart-stacks can fix. What it does do:
the generated SSH config adds keepalives so a dead VM disconnects in ~45s
instead of hanging, `tart run`'s stderr is captured to
`~/Library/Logs/tart-stacks/<name>.run.log` (a crash's `fixme:` line lands
there; a full report goes to `~/Library/Logs/DiagnosticReports/tart-*.ips`),
and `tart-up` recognises the wedged state and names the remedy instead of
timing out against a ghost:

```sh
ssh tart-app-a
# tart-up: 'app-a' is listed as running, but no 'tart run app-a' process
#          exists — likely crashed or wedged.
# tart-up: run 'tart stop app-a' then retry ssh.

tart stop app-a && ssh tart-app-a    # back up
```

Recovery is deliberately manual. A VM does nothing useful without a shell or a
VNC viewer attached to it, and the forwarded ports that make it useful are
`RemoteForward`s riding your SSH session — they die with the session and come
back when you reconnect, which is also what starts the VM again. Restarting a
crashed VM in the background would therefore restore an empty machine that
nobody is talking to.

## Adding a new stack

1. `make scaffold STACK=<name>` — stamps `stacks/<name>/` from `templates/stack/`: a generic `00-stack.sh` (reads `packages.<family>` for the build distro), a `mise-install.sh` with a hard-gate smoke test, `files/mise.toml`, `packages.dnf`, `packages.apt`, and a `README.md`. One parameterized root `stack.pkr.hcl` already covers every stack — there's no per-stack Packer file to write.
2. Edit `files/mise.toml` (tool versions) and `scripts/mise-install.sh` (install + smoke test). If the stack needs native build deps (e.g., compile-from-source runtimes), add them to `packages.dnf` (Fedora/dnf names) and `packages.apt` (Debian/Ubuntu/apt names) — keep the two files aligned.
3. `make build STACK=<name> DISTRO=<distro>` — or `packer validate -var stack=<name> -var distro=<distro> stack.pkr.hcl` for a fast HCL pre-check. `<distro>` must appear in `shared/linux/os`.
4. Add a row to the stack table at the top of this README. CI auto-discovers `stacks/*/` and cross-products with `shared/linux/os` — no workflow edit needed.

## Adding a distro

1. Add the distro token (one line) to `shared/linux/os`.
2. Confirm a `ghcr.io/cirruslabs/<distro>` Tart image exists (Cirrus must publish it).
3. Another **apt-family** distro needs nothing further — the apt branch is portable apt/dpkg only, so a Debian or Ubuntu derivative works with the steps above. The dnf branch is **Fedora-specific** (`rpm -E %fedora` builds a Fedora-release COPR URL, plus `copr enable` and the `development-tools` group), so an enterprise rebuild such as `rocky` is refused by `_detect_family` rather than failed partway through a build. A **new package family** is a code change, not configuration: add a branch to `shared/linux/scripts/family-lib.sh` exporting `_TART_FAMILY` and implementing `pkg_install`, `pkg_install_optional`, `pkg_group_devtools`, `pkg_refresh`, `pkg_clean` and the relevant `repo_add_*` functions — plus `pkg_release_upgrade`, `install_guest_agent` and `assert_mac_enforcing`, which deliberately fail closed for a family they have no branch for rather than letting it inherit an unmanaged release, an unmanaged guest agent, or an unverified MAC posture; add a `packages.<family>` file to each stack; and add a matching `provisioner "file"` block to `stack.pkr.hcl`, which uploads `packages.dnf`/`packages.apt` by name — without it `00-stack.sh` reads the absent file as an empty package list and installs nothing.
4. For each stack that has native build deps, add the equivalent packages to `packages.<new-family>` in that stack's directory.
5. CI picks up the new distro automatically (matrix is `stacks/*` × `shared/linux/os`).

## Troubleshooting

- **`packer init` fails with "no plugins for github.com/cirruslabs/tart"** → upgrade Packer (`brew upgrade hashicorp/tap/packer`); the tart plugin requires Packer 1.7+.
- **Build fails within a minute: "no enabled tart-guest-agent.service"** (or "enabled but not running") → the base image you bootstrapped from carries no working guest agent. `tart exec` — which `tart-up` uses to set a clone's hostname and to activate every GUI mode — is served by a daemon *inside* the VM, so installing Tart on the host cannot supply it. Cirrus's images include it; a hand-rolled or vanilla cloud base may not. Re-pull a base with `make bootstrap DISTRO=<distro>`, or install `tart-guest-agent` into the base image and enable its unit.
- **Build hangs at "Waiting for SSH"** → usually a Tart networking hiccup. Open a second terminal: `tart ip <distro>-base` (e.g. `tart ip fedora-base`). If blank, the VM didn't get DHCP — `tart stop <distro>-base; tart delete <distro>-base; make bootstrap DISTRO=<distro>` to start over.
- **`ssh tart-<name>` triggers Touch ID more than once** → `~/.ssh/config.d/tart-vms` isn't being matched (missing `Include` line, or it's below a `Host *` catch-all), so ssh falls back to defaults and offers every key in Secretive's agent — one Touch ID prompt per key tried. The generated config pins just the Tart VM key (`IdentityFile` + `IdentitiesOnly yes`), so a match is what collapses it to a single prompt. Re-run `make setup` — it adds the `Include` line and warns if an existing one is misplaced. See [Setup §2](#2-install-the-host-tools).
- **All SSH sessions to a VM drop at once / "broken pipe", and the VM loses forwarded host services** → the VM's `tart run` process crashed (often an Apple Virtualization.framework trap; check `~/Library/Logs/tart-stacks/<name>.run.log` and `~/Library/Logs/DiagnosticReports/tart-*.ips`). Bring it back with `tart stop <name>` then `ssh tart-<name>`. Recovery is manual by design — see [When a VM crashes](#when-a-vm-crashes).

Stack-specific troubleshooting lives in each stack's README.

## License

MIT — see [LICENSE](./LICENSE).
