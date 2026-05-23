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

## Out of scope (inherited trust)

The base images rely on the following upstream sources for their content. Vulnerabilities in these should be reported upstream, not here:

- `ghcr.io/cirruslabs/fedora:latest` — the base Fedora image; built from [`cirruslabs/linux-image-templates`](https://github.com/cirruslabs/linux-image-templates).
- `mise.run` — the [mise](https://mise.jdx.dev/) install script.
- `claude.ai/install.sh` — the [Claude Code](https://claude.ai/) native installer.
- `download.docker.com/linux/fedora/docker-ce.repo` — Docker CE's official Fedora repository.
- `varlad/zellij` — the [zellij](https://github.com/zellij-org/zellij) COPR.

Stack-specific upstream sources:

- **`fedora-php`** — `getcomposer.org/installer`, verified against `composer.github.io/installer.sig` (SHA-384).

The only verification this repo adds on top of these is the Composer SHA-384 check in `stacks/fedora-php/scripts/mise-install.sh`. If you spot a missing verification on any of the above, that's a valid finding for this repo — please report.

## Supported versions

This is a personal base-image collection, not a published distribution. Only the `trunk` branch is supported. Cut a fresh build (`make rebuild STACK=<name>`) to pick up upstream fixes.
