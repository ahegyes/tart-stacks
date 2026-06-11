SHELL := /bin/bash
.PHONY: help setup uninstall test smoke init bootstrap build rebuild scaffold clean check-stack check-stack-name list-stacks check-distro

# Stack selector. Required for build/rebuild/scaffold. e.g. `make build STACK=php DISTRO=fedora`.
STACK ?=

# Distro selector. Required for build/rebuild/bootstrap. Must be a line in shared/distros.
DISTRO ?=

# Override to pin a non-latest base image tag: `IMAGE_TAG=24.04 make bootstrap DISTRO=ubuntu`.
IMAGE_TAG ?= latest

# Intermediate Tart base image (per distro). `bootstrap` clones the Cirrus image
# into <distro>-base; the parameterized build clones from it.
TART_BASE_NAME = $(DISTRO)-base

STACK_DIR := stacks/$(STACK)

help:
	@echo "tart-stacks — common commands"
	@echo ""
	@echo "  make setup                                Install host tools onto your Mac (run once): symlinks all commands + completions,"
	@echo "                                            adds the SSH Include and scaffolds the forwards + mounts config"
	@echo "  make uninstall                            Remove the host tools from your Mac (inverse of setup); per-VM config files are kept"
	@echo "  make test                                 Run the test suite (test/*.sh)"
	@echo "  make list-stacks                          List available stacks"
	@echo "  make scaffold STACK=<name>                Create a new stack from templates/stack/"
	@echo "  make init                                 Install the Packer plugin (run once)"
	@echo "  make build STACK=<name> DISTRO=<distro>   Bootstrap + build the stack image"
	@echo "  make rebuild STACK=<name> DISTRO=<distro> Force-rebuild — overwrites existing image"
	@echo "  make smoke STACK=<name> DISTRO=<distro>   Smoke-test a BUILT image end-to-end: clone, boot a real VM (~1 min), ssh, assert, destroy. Local-only — never run in CI"
	@echo "  make clean                                Remove Packer build artifacts"
	@echo ""
	@echo "  DISTRO — required distro token (e.g. fedora). Must be listed in shared/distros."
	@echo "  IMAGE_TAG — override the base image tag (default: latest). e.g. IMAGE_TAG=42 make bootstrap DISTRO=fedora"

list-stacks:
	@ls -1 stacks 2>/dev/null | sed 's/^/  /' || echo "  (none)"

# Host-side install (macOS). Idempotent; safe to re-run. Logic lives in
# script/setup so the SSH-config validation stays testable.
setup:
	@"$(CURDIR)/script/setup"

# Inverse of setup — same script, so the supervised-VM gate and the
# ownership/marker checks stay testable. Per-VM config files are kept.
uninstall:
	@"$(CURDIR)/script/setup" --uninstall

# Run the plain-bash test suite (test/*.sh). No framework; needs only bash + jq.
test:
	@"$(CURDIR)/script/test"

# Validate that STACK is set and the requested stack directory exists.
# build/rebuild depend on this.
check-stack:
	@if [ -z "$(STACK)" ]; then \
		echo "ERROR: STACK is required (e.g., make build STACK=php DISTRO=fedora). Available stacks:" >&2; \
		ls -1 stacks 2>/dev/null | sed 's/^/  /' >&2 || echo "  (none)" >&2; \
		exit 1; \
	fi
	@if [ ! -d "$(STACK_DIR)" ]; then \
		echo "ERROR: stack '$(STACK)' not found at $(STACK_DIR)/. Available stacks:" >&2; \
		ls -1 stacks 2>/dev/null | sed 's/^/  /' >&2 || echo "  (none)" >&2; \
		exit 1; \
	fi

# Like check-stack but for a NEW stack: STACK must be set and a bare
# lowercase-alphanumeric token; the dir must NOT exist. The token gate is
# load-bearing: scaffold interpolates STACK into mkdir paths and a sed
# replacement, so a '/' or '&' would mkdir a nested tree or corrupt every
# stamped file — and the half-scaffolded dir then blocks reruns and gets
# discovered by CI as a stack.
check-stack-name:
	@if [ -z "$(STACK)" ]; then \
		echo "ERROR: STACK is required (e.g., make scaffold STACK=python)." >&2; \
		exit 1; \
	fi
	@if ! printf '%s\n' "$(STACK)" | grep -qE '^[a-z0-9]+$$'; then \
		echo "ERROR: STACK must be a lowercase alphanumeric token, got '$(STACK)' (e.g., make scaffold STACK=python)." >&2; \
		exit 1; \
	fi

# Validate DISTRO is set and supported (a non-comment line in shared/distros).
check-distro:
	@if [ -z "$(DISTRO)" ]; then \
		echo "ERROR: DISTRO is required (e.g., make build STACK=php DISTRO=fedora). Supported distros:" >&2; \
		grep -vE '^\s*(#|$$)' shared/distros | sed 's/^/  /' >&2; \
		exit 1; \
	fi
	@if ! grep -qxF "$(DISTRO)" <(grep -vE '^\s*(#|$$)' shared/distros); then \
		echo "ERROR: distro '$(DISTRO)' is not supported. Add it to shared/distros (and a branch in distro-lib.sh) first. Supported:" >&2; \
		grep -vE '^\s*(#|$$)' shared/distros | sed 's/^/  /' >&2; \
		exit 1; \
	fi

# Install the Packer plugin for the single parameterized root template (run once,
# stack-agnostic).
init:
	@command -v packer >/dev/null 2>&1 || { echo "packer not installed. Run: brew install hashicorp/tap/packer"; exit 1; }
	packer init .

bootstrap: check-distro
	@command -v tart >/dev/null 2>&1 || { echo "tart not installed. Run: brew install cirruslabs/cli/tart"; exit 1; }
	tart pull ghcr.io/cirruslabs/$(DISTRO):$(IMAGE_TAG)
	-tart delete $(TART_BASE_NAME) 2>/dev/null
	tart clone ghcr.io/cirruslabs/$(DISTRO):$(IMAGE_TAG) $(TART_BASE_NAME)

# Build a stack from the one parameterized template, run from the repo root so
# the provisioner script paths (shared/…, stacks/<stack>/…) resolve.
build: check-stack check-distro bootstrap
	packer build -var stack=$(STACK) -var distro=$(DISTRO) stack.pkr.hcl

rebuild: check-stack check-distro bootstrap
	packer build -force -var stack=$(STACK) -var distro=$(DISTRO) stack.pkr.hcl

# End-to-end proof of a BUILT image (clone → boot → ssh → assert → destroy).
# Boots a real VM, so it stays a local dev-task — GitHub runners can't run
# Tart VMs (no nested virtualization), hence deliberately absent from CI.
smoke: check-stack check-distro
	@"$(CURDIR)/script/smoke" "$(STACK)" "$(DISTRO)"

# Scaffold a new stack from templates/stack/ (substitutes __STACK__). Refuses to
# clobber an existing dir; the root template + dynamic CI then cover it with no
# further wiring.
scaffold: check-stack-name
	@if [ -d "$(STACK_DIR)" ]; then \
		echo "ERROR: $(STACK_DIR)/ already exists — refusing to overwrite." >&2; \
		exit 1; \
	fi
	@mkdir -p "$(STACK_DIR)/scripts" "$(STACK_DIR)/files"
	@for f in $$(cd templates/stack && find . -type f); do \
		dest="$(STACK_DIR)/$${f#./}"; dest="$${dest%.tmpl}"; \
		mkdir -p "$$(dirname "$$dest")"; \
		sed 's/__STACK__/$(STACK)/g' "templates/stack/$${f#./}" > "$$dest"; \
	done
	@chmod +x "$(STACK_DIR)"/scripts/*.sh
	@echo "scaffolded $(STACK_DIR)/ — next:"
	@echo "  1. edit $(STACK_DIR)/files/mise.toml (tool versions)"
	@echo "  2. in scripts/mise-install.sh, add ONE smoke_gate check per tool — a"
	@echo "     missing check ships an unverified runtime (the gate only tests what you list)"
	@echo "  3. make build STACK=$(STACK) DISTRO=<distro>"
	@echo "  4. add a row to the stack table in README.md"

# Clean Packer artifacts at the repo root and inside every stack directory
# (packer creates these next to the cwd / .pkr.hcl it was invoked from).
clean:
	rm -rf packer_cache/ output-*/ *.log crash.log
	@for d in stacks/*/; do \
		rm -rf "$$d"packer_cache "$$d"output-* "$$d"*.log "$$d"crash.log 2>/dev/null || true; \
	done
