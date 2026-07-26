# Contributing to tart-stacks

Small project; PRs welcome.

## Setup

You'll need a macOS host (Apple Silicon, M1 or later, macOS 26+ — see the README's Prerequisites for why) and:

- [Tart](https://tart.run/): `brew install openai/tools/tart`
- [Packer](https://www.packer.io/): `brew install hashicorp/tap/packer`
- [jq](https://jqlang.org/): `brew install jq` — the host commands and the test suite parse JSON with it
- [ShellCheck](https://www.shellcheck.net/): `brew install shellcheck` — to mirror the CI lint locally

See the [README](./README.md) for the Secure Enclave SSH key + SSH config setup (steps 1-3 of the Setup section). Each stack's Packer build authorizes whatever key you point `var.ssh_pubkey_path` at (the generated SSH config pins `~/.ssh/tart-vm.pub`, so symlink your key there rather than overriding the var — README Setup step 1) — without it the build won't run.

## Making changes

1. Edit the relevant `shared/scripts/*.sh`, `stacks/<name>/scripts/*.sh`, or `*/files/*` file.
2. Fast pre-checks — mirror the CI gates locally:
   - `packer validate -var stack=<name> -var distro=<distro> stack.pkr.hcl` (from the repo root, ~1s, HCL syntax) and `bash -n` on any script you changed — **syntax only, not proof of runtime behavior**.
   - `make test` — the plain-bash test suite (`test/*.sh`), exactly what the CI tests job runs.
   - `shellcheck` on any script you changed — the CI job fails on shellcheck **warnings**, not just errors, so locally-clean is the bar. (Scaffold templates get linted too, with `__STACK__` substituted; see `.github/workflows/validate.yml`.)
3. For anything that touches a provisioner or a file baked into the image, a real rebuild is the **only** behavioral proof — `make rebuild STACK=<name> DISTRO=<distro>` (15-20 min for PHP). Follow with `make smoke STACK=<name> DISTRO=<distro>` (~1 min; boots a real VM, so local-only). The manual equivalent, for poking around inside:
   ```bash
   tart-new test-vm <name> <distro>   # guarded clone
   ssh tart-test-vm                   # auto-starts the stopped VM, then connects
   # inside the VM (example for the php stack):
   node --version && php --version && composer --version
   exit                               # back to the host — tart-rm is host-side
   tart-rm test-vm                    # guarded teardown when done
   ```

> **`script/` vs `scripts/`:** `script/` (singular) holds host tooling — `setup`, `smoke`, and `test`, run via `make`. `shared/scripts/` and `stacks/*/scripts/` (plural) are the in-VM provisioners. The one-character difference is intentional but easy to trip on.

## PR conventions

- **One logical change per PR.** Renaming + a bug fix in the same PR is two PRs.
- **`shared/` changes affect every stack.** Bear that in mind — a tweak that helps one stack may regress another.
- **If you add a new script** to an existing stack, reference it from the root `stack.pkr.hcl` provisioner block (parameterized by `var.stack`). To add a new stack, run `make scaffold STACK=<name>` and add a row to the stack table in the top-level `README.md` — CI runs `packer validate` for every `stacks/*/` × `shared/distros` cell automatically, no workflow edit needed for new stacks or new distros.
- **Comments explain WHY, not WHAT** — see [`AGENTS.md`](./AGENTS.md) for the full convention list.

## Reporting bugs

Open a [GitHub issue](https://github.com/ahegyes/tart-stacks/issues) with:

- macOS version, Tart version, Packer version (`brew list --versions tart packer`).
- The stack you were building (`STACK=...`).
- The relevant excerpt of `make build` output, with context (~30 lines around the failure is usually enough).
- What you expected vs. what happened.

For security issues, see [SECURITY.md](./SECURITY.md) — don't open a public issue.
