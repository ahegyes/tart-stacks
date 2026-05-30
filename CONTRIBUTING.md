# Contributing to tart-stacks

Small project; PRs welcome.

## Setup

You'll need a macOS host (Apple Silicon, M1 or later, macOS 13+) and:

- [Tart](https://tart.run/): `brew install cirruslabs/cli/tart`
- [Packer](https://www.packer.io/): `brew install hashicorp/tap/packer`

See the [README](./README.md) for the Secure Enclave SSH key + SSH config setup (steps 1-3 of the Setup section). Each stack's Packer build authorizes whatever key you point `var.ssh_pubkey_path` at — without it the build won't run.

## Making changes

1. Edit the relevant `shared/scripts/*.sh`, `stacks/<name>/scripts/*.sh`, or `*/files/*` file.
2. Fast pre-checks — **syntax only, not proof of runtime behavior**: `packer validate -var stack=<name> stack.pkr.hcl` (from the repo root, ~1s, HCL syntax) and `bash -n` on any script you changed.
3. For anything that touches a provisioner or a file baked into the image, a real rebuild is the **only** behavioral proof — `make rebuild STACK=<name>` (15-20 min for PHP), then confirm a fresh clone works:
   ```bash
   tart clone fedora-<name> test-vm
   ssh tart-test-vm            # auto-starts the stopped VM, then connects
   # inside VM (example for fedora-php):
   node --version && php --version && composer --version
   ```

> **`script/` vs `scripts/`:** `script/` (singular) holds host tooling — `setup` and `test`, run via `make`. `shared/scripts/` and `stacks/*/scripts/` (plural) are the in-VM provisioners. The one-character difference is intentional but easy to trip on.

## PR conventions

- **One logical change per PR.** Renaming + a bug fix in the same PR is two PRs.
- **`shared/` changes affect every stack.** Bear that in mind — a tweak that helps one stack may regress another.
- **If you add a new script** to an existing stack, reference it from the root `stack.pkr.hcl` provisioner block (parameterized by `var.stack`). To add a new stack, run `make scaffold STACK=<name>` and add a row to the stack table in the top-level `README.md` — CI discovers `stacks/fedora-*/` automatically, no workflow edit.
- **Comments explain WHY, not WHAT** — see [`AGENTS.md`](./AGENTS.md) for the full convention list.

## Reporting bugs

Open a [GitHub issue](https://github.com/ahegyes/tart-stacks/issues) with:

- macOS version, Tart version, Packer version (`brew list --versions tart packer`).
- The stack you were building (`STACK=...`).
- The relevant excerpt of `make build` output, with context (~30 lines around the failure is usually enough).
- What you expected vs. what happened.

For security issues, see [SECURITY.md](./SECURITY.md) — don't open a public issue.
