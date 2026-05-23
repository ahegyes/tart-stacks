# Contributing to tart-stacks

Small project; PRs welcome.

## Setup

You'll need a macOS host (Apple Silicon, M1 or later, macOS 13+) and:

- [Tart](https://tart.run/): `brew install cirruslabs/cli/tart`
- [Packer](https://www.packer.io/): `brew install hashicorp/tap/packer`

See the [README](./README.md) for the Secure Enclave SSH key + SSH config setup (steps 1-3 of the Setup section). Each stack's Packer build authorizes whatever key you point `var.ssh_pubkey_path` at — without it the build won't run.

## Making changes

1. Edit the relevant `shared/scripts/*.sh`, `stacks/<name>/scripts/*.sh`, or `*/files/*` file.
2. Run `cd stacks/<name> && packer validate stack.pkr.hcl` — ~1s; catches HCL syntax errors.
3. Run `bash -n` on any script you changed.
4. For non-trivial changes: `make rebuild STACK=<name>` (15-20 min for PHP) and confirm a fresh clone works:
   ```bash
   tart clone fedora-<name> test-vm
   tart run test-vm --no-graphics &
   tssh test-vm
   # inside VM (example for fedora-php):
   node --version && php --version && composer --version && docker --version
   ```

## PR conventions

- **One logical change per PR.** Renaming + a bug fix in the same PR is two PRs.
- **`shared/` changes affect every stack.** Bear that in mind — a tweak that helps one stack may regress another.
- **If you add a new script** to an existing stack, reference it from that stack's `stack.pkr.hcl` provisioner block. If you add a new stack, also add it to the CI matrix in `.github/workflows/validate.yml` and the stack table in the top-level `README.md`.
- **Add a `CHANGELOG.md` entry** under `## [Unreleased]` for user-visible changes.
- **Comments explain WHY, not WHAT** — see [`AGENTS.md`](./AGENTS.md) for the full convention list.

## Reporting bugs

Open a [GitHub issue](https://github.com/ahegyes/tart-stacks/issues) with:

- macOS version, Tart version, Packer version (`brew list --versions tart packer`).
- The stack you were building (`STACK=...`).
- The relevant excerpt of `make build` output, with context (~30 lines around the failure is usually enough).
- What you expected vs. what happened.

For security issues, see [SECURITY.md](./SECURITY.md) — don't open a public issue.
