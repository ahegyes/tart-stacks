# Security

## Reporting a vulnerability

Please report security vulnerabilities via GitHub's Private Vulnerability Reporting:

1. Go to the [Security tab](https://github.com/ahegyes/tart-stacks/security) of this repository.
2. Click **Report a vulnerability**.
3. Describe the issue with reproduction steps.

GitHub routes the report to the maintainer's notifications inbox without exposing any email address. Follow-up happens privately in the same advisory thread, and a CVE can be issued from there if appropriate.

Please do not open a public issue for security reports.

## Security model — the base images

Every stack inherits the same hardened SSH posture from `shared/scripts/99-finalize.sh`:

- **No password authentication.** `99-finalize.sh` writes `/etc/ssh/sshd_config.d/00-vm-hardening.conf` with `PasswordAuthentication no`, `PermitRootLogin no`, and `KbdInteractiveAuthentication no`. The `00-` prefix is load-bearing — it wins over cloud-init's `50-cloud-init.conf` which re-enables password auth.
- **Admin password locked.** `99-finalize.sh` runs `passwd -l admin`, setting the hash to `!`. Password login, `su`, and password-based `sudo` are all impossible. Only the SSH key authorized by `99-finalize.sh` (same script) grants access.
- **NOPASSWD sudo for admin.** A `/etc/sudoers.d/admin-nopasswd` drop-in (validated with `visudo -cf` before landing on disk) ensures interactive `sudo` still works inside clones, since the password is locked.
- **The base images are intended only as clone sources.** They should never be booted directly or exposed to a network on their own. Clones get the hardened sshd config on first boot.
- **Optional network egress confinement.** `~/.config/tart-stacks/netpolicy` (consumed by `tart-up`, applied at VM start — not baked into the image) passes Tart `--net-*` flags to restrict a VM's outbound network; see the [README](./README.md#5-network-egress-policy-optional). Absent ⇒ default unfiltered NAT.

## Out of scope (inherited trust)

The base images rely on the following upstream sources for their content. Vulnerabilities in these should be reported upstream, not here:

- `ghcr.io/cirruslabs/<distro>:latest` (fedora/ubuntu/debian per `shared/distros`) — the base distro images; built from [`cirruslabs/linux-image-templates`](https://github.com/cirruslabs/linux-image-templates).

dnf-family (Fedora) sources:
- `copr.fedorainfracloud.org/coprs/jdxcode/mise` — the [mise](https://mise.jdx.dev/) COPR.
- `copr.fedorainfracloud.org/coprs/varlad/zellij` — the [zellij](https://github.com/zellij-org/zellij) COPR.

apt-family (Debian/Ubuntu) sources:
- `mise.jdx.dev/gpg-key.pub` + `mise.jdx.dev/deb` — the signed mise apt repo.
- `cli.github.com/packages/githubcli-archive-keyring.gpg` + `cli.github.com/packages` — the GitHub CLI signed apt repo.
- `github.com/zellij-org/zellij/releases/latest` — the zellij static-musl release tarball (no apt package exists).

Stack-specific upstream sources:

- **php stack** — `getcomposer.org/installer`, verified against `composer.github.io/installer.sig` (SHA-384).

The verifications this repo adds on top of upstream's own: the Composer SHA-384 check in `stacks/php/scripts/mise-install.sh`, and (on apt-family distros) a sha256 check of the downloaded zellij binary against its published `.sha256sum` in `shared/scripts/distro-lib.sh`. If you spot a missing verification on any of the above, that's a valid finding for this repo — please report.

## Supported versions

This is a personal base-image collection, not a published distribution. Only the `trunk` branch is supported. Cut a fresh build (`make rebuild STACK=<name> DISTRO=<distro>`) to pick up upstream fixes.
