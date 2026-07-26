# Foo

<One line: what this stack is for.> Builds a `<distro>-Foo` Tart image; clone
it per-project with `tart-new <name> Foo <distro>`.

For host setup, build flow, and daily use, see the [top-level README](../../README.md).
This file documents what's in *this* stack.

## What's in this stack

- **\<runtime\>** — version-managed via mise ([`files/mise.toml`](./files/mise.toml)).

## Customization

- **Tool versions**: [`files/mise.toml`](./files/mise.toml).
- **Stack-specific build deps**: add packages to [`packages.dnf`](./packages.dnf) (Fedora/dnf names) and [`packages.apt`](./packages.apt) (Debian/Ubuntu/apt names) — keep both aligned. [`scripts/00-stack.sh`](./scripts/00-stack.sh) reads the appropriate file for the distro being built.
