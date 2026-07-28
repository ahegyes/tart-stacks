# Security

## Reporting a vulnerability

Please report security vulnerabilities via GitHub's Private Vulnerability Reporting:

1. Go to the [Security tab](https://github.com/ahegyes/tart-stacks/security) of this repository.
2. Click **Report a vulnerability**.
3. Describe the issue with reproduction steps.

GitHub routes the report to the maintainer's notifications inbox without exposing any email address. Follow-up happens privately in the same advisory thread, and a CVE can be issued from there if appropriate.

Please do not open a public issue for security reports.

## Security model — the base images

Every **linux** stack inherits the same hardened SSH posture from `shared/linux/scripts/99-finalize.sh`:

- **No password authentication.** `99-finalize.sh` writes `/etc/ssh/sshd_config.d/00-vm-hardening.conf` with `PasswordAuthentication no`, `PermitRootLogin no`, and `KbdInteractiveAuthentication no`. The `00-` prefix is load-bearing — it wins over cloud-init's `50-cloud-init.conf` which re-enables password auth.
- **Admin password locked.** `99-finalize.sh` runs `passwd -l admin`, setting the hash to `!`. Password login, `su`, and password-based `sudo` are all impossible. Over the network, only the SSH key authorized by `99-finalize.sh` (same script) grants access — with two exceptions that are not network paths: on GUI images a display-manager autologin also opens a console session (next bullet), and from the host itself, `tart exec` reaches the `admin` account with NOPASSWD sudo over `tart-guest-agent`'s vsock channel, with no key and no Touch ID (see [Out of scope](#out-of-scope-inherited-trust)). Both are host-side by design — the host owns the VM — but neither is revoked by rotating the SSH key.
- **NOPASSWD sudo for admin.** A `/etc/sudoers.d/admin-nopasswd` drop-in (validated with `visudo -cf` before landing on disk) ensures interactive `sudo` still works inside clones, since the password is locked.
- **The base images are intended only as clone sources.** They should never be booted directly or exposed to a network on their own. Clones get the hardened sshd config on first boot.
- **GUI images add a console and a loopback VNC surface.** A `GUI=1` build bakes display-manager autologin for the `admin` account and a TigerVNC session with `SecurityTypes=None`, bound to `127.0.0.1` only — reached over an SSH tunnel, so the SSH key remains the authentication. Anyone who can see the VM's window or reach that tunnel has the account, NOPASSWD sudo included. Full contract: [`shared/linux/gui/README.md`](./shared/linux/gui/README.md).
- **Optional network egress confinement.** `~/.config/tart-stacks/netpolicy` (consumed by `tart-up`, applied at VM start — not baked into the image) passes Tart `--net-*` flags to restrict a VM's outbound network; see the [README](./README.md#5-network-egress-policy-optional). Absent ⇒ default unfiltered NAT.

### macOS (darwin) diverges deliberately

`shared/darwin/scripts/99-finalize.sh` establishes a different final posture than the linux script above, on purpose in one place:

- **Same key-only SSH.** It writes the same `PasswordAuthentication no` / `PermitRootLogin no` / `KbdInteractiveAuthentication no` drop-in and authorizes the same SSH key via the same `assert_authorized_key_safe` gate (`shared/scripts/authorized-key-lib.sh`), then asserts the listener surface is `:22` alone before finishing.
- **Same NOPASSWD sudo, asserted rather than installed.** Cirrus's base already ships `/etc/sudoers.d/<user>-nopasswd`; `assert_nopasswd_sudo` (`shared/darwin/scripts/family-lib.sh`) verifies the grant is real (queries the sudoers *policy* via `sudo -l -U`, not just that the file parses) rather than writing a new one.
- **The base's remote-access services are disabled, not merely left alone.** Cirrus's macOS base ships Screen Sharing listening on `*:5900` and a Kerberos KDC on `*:88`, both reachable with the publicly-known `admin`/`admin` credentials; `99-finalize.sh` disables both via `launchctl disable`/`bootout` before writing the manifest.
- **The account password is never locked — a deliberate divergence from the linux images above.** Linux runs `passwd -l admin`; darwin never runs the equivalent. A GUI console session (`tart-up --gui=window`) depends on a display-manager autologin that is already open at boot, so a locked password would make a greeter a dead end, and — unlike a fresh lock — a *randomized* one would be unrecoverable without the original (SecureToken-gated reset). The manifest records this explicitly (`password: unlocked (console-only; sshd is key-only)`) so a reader doesn't mistake it for an oversight. This does not weaken the network-facing posture: the account is reachable over the network only through the same SSH-key gate as linux, since password auth is disabled in sshd regardless of whether the account password itself is locked. It does mean anyone who can see the VM's console (a GUI boot, or `tart exec` from the host) already has the account — same trust boundary as the linux "Admin password locked" bullet's own carve-outs above.

## Out of scope (inherited trust)

The base images rely on the following upstream sources for their content. Vulnerabilities in these should be reported upstream, not here:

- `ghcr.io/cirruslabs/<os>:latest` (fedora/ubuntu/debian per `shared/linux/os`) — the base OS images; built from [`cirruslabs/linux-image-templates`](https://github.com/cirruslabs/linux-image-templates).
- `ghcr.io/cirruslabs/macos-<release>-base` (macos per `shared/darwin/os`; the release is the Makefile's `MACOS_RELEASE`, e.g. `tahoe`) — the darwin base image `make bootstrap OS=macos` clones; built from [`cirruslabs/macos-image-templates`](https://github.com/cirruslabs/macos-image-templates). Unlike the linux images, there is no rolling tag under the OS name itself — a release ships and stays put — so this pin does not go stale the way an unattended Fedora base would; it goes stale only when nobody bumps `MACOS_RELEASE`.
  - Present in those images but **replaced by this repo, not inherited**: [`tart-guest-agent`](https://github.com/openai/tart-guest-agent), the in-guest daemon that answers the host's `tart exec` calls over vsock. It runs as a service inside every VM built here and executes what the host asks of it against a NOPASSWD-sudo account, so its version is a deliberate choice rather than an accident of which base was current. `shared/linux/scripts/00-base.sh` installs the pinned `TART_GUEST_AGENT_VERSION` (see the release-download entry below), then asserts the unit is enabled and running; `script/smoke` proves the channel answers. Left inherited, the version silently forked across cells — a frozen base carried 0.10.0 while weekly-rebuilt ones carried 0.11.0 — and no OS repository ships the package, so a release upgrade cannot carry it forward either.
  - **The OS release those images are published at is not what a built image ships.** The upstream Fedora image is pinned to a release that is already past end of life, and its publisher advances that by hand, so re-pulling the base never moves it. The build's first provisioner therefore calls `pkg_release_upgrade` (defined in `shared/linux/scripts/family-lib.sh`), lifting a dnf-family guest to `FEDORA_TARGET_RELEASE` before anything is installed on it. Packages come from Fedora's own repositories and are verified against a signing key that already ships in the base image — no key is fetched at build time, and `--nogpgcheck` is never used. `00-base.sh` then refuses outright any release whose own `SUPPORT_END` has passed, so a stale pin fails the build rather than quietly producing an unpatched image. The apt-family bases are current and their publisher tracks them, so this is a no-op there.

dnf-family (Fedora) sources:
- `copr.fedorainfracloud.org/coprs/jdxcode/mise` — the [mise](https://mise.jdx.dev/) COPR.
- `copr.fedorainfracloud.org/coprs/varlad/zellij` — the [zellij](https://github.com/zellij-org/zellij) COPR.

apt-family (Debian/Ubuntu) sources:
- `mise.jdx.dev/gpg-key.pub` + `mise.jdx.dev/deb` — the signed mise apt repo.
- `cli.github.com/packages/githubcli-archive-keyring.gpg` + `cli.github.com/packages` — the GitHub CLI signed apt repo.
- `github.com/zellij-org/zellij/releases/latest` — the zellij static-musl release tarball (no apt package exists).

brew-family (darwin) sources:
- `homebrew-core` (Homebrew's default tap) — every formula this platform installs: `stacks/*/packages.brew`'s native build deps, plus `mise`, `zellij` and `jq` in `shared/darwin/scripts/00-base.sh`. Unlike the dnf/apt families, there is no separate COPR/signed-repo indirection to add — `shared/darwin/scripts/family-lib.sh`'s own header notes brew already IS the repo, so formulae install directly via `brew install` with no `repo_add_*` step of their own. Homebrew's own formula pinning and bottle-checksum verification is what this repo relies on; no additional hash check is added on top for these installs.

Both linux families (dnf and apt):
- `github.com/openai/tart-guest-agent/releases` — the pinned agent's `.rpm`/`.deb`, verified against that release's published `_checksums.txt` before it reaches the package manager (`install_guest_agent` in `shared/linux/scripts/family-lib.sh`). This is the most privileged download in the build: the binary it installs executes host-issued commands as an account with passwordless sudo, so an unlisted or mismatched artifact is refused rather than installed. There is no darwin equivalent of this download: Cirrus's macOS base ships the guest agent's LaunchDaemon + LaunchAgent pair already, so `shared/darwin/scripts/family-lib.sh`'s `install_guest_agent` only asserts the pair is present rather than fetching anything.

Runtime sources fetched at build time (a class, not an exhaustive list — the exact set follows each stack's `files/mise.toml`):
- Everything mise resolves and downloads for the tools declared in the per-stack `files/mise.toml` — e.g. php-src (compiled via the vfox-php plugin), the Node dist tarballs, Temurin JDK via the Adoptium API, the Maven/Gradle/sbt/Kotlin/scala-cli release artifacts, uv. Each download's integrity is whatever mise and the respective backend enforce.
- `pecl.php.net` — the PECL extensions the php stack's `scripts/{linux,darwin}/mise-install.sh` install.

Stack-specific upstream sources:

- **php stack** — `getcomposer.org/installer`, verified against `composer.github.io/installer.sig` (SHA-384).

The verifications this repo adds on top of upstream's own: the sha256 check of the tart-guest-agent package against its release checksums (both linux families — there is no darwin equivalent to check, since that platform only asserts the agent Cirrus already ships), the Composer SHA-384 check in `stacks/php/scripts/{linux,darwin}/mise-install.sh`, and (on apt-family OSes) a sha256 check of the downloaded zellij binary against its published `.sha256sum` — all in `shared/linux/scripts/family-lib.sh` unless noted. If you spot a missing verification on any of the above, that's a valid finding for this repo — please report.

## Supported versions

This is a personal base-image collection, not a published distribution. Only the `trunk` branch is supported. Cut a fresh build (`make rebuild STACK=<name> OS=<os>`) to pick up upstream fixes.
