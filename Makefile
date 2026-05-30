.PHONY: help setup test init bootstrap build rebuild scaffold clean check-stack check-stack-name list-stacks

# Stack selector. Required for build/rebuild/scaffold. e.g. `make build STACK=php`.
# Resolves to stacks/fedora-$(STACK)/.
STACK ?=

# Override to pin a non-latest Fedora tag: `FEDORA_TAG=42 make bootstrap`.
# Cirrus publishes `latest`, `42`, `39`, `38`, but 39/38 ship dnf4 and break
# docker.sh. Effective supported set: `latest`, `42`.
FEDORA_TAG ?= latest

# Intermediate Tart base image (shared across stacks). `bootstrap` clones the
# Cirrus image into this name; the parameterized build then clones from it.
TART_BASE_NAME ?= fedora-base

STACK_DIR := stacks/fedora-$(STACK)

# Stacks that bake in a Docker engine (opt-in; new stacks get none). php = wp-env;
# jvm = container-based cluster proxies. Longer term this moves to per-profile
# workbench provisioning so the base image itself stays Docker-free.
WITH_DOCKER_php := true
WITH_DOCKER_jvm := true
DOCKER_VAR := $(if $(WITH_DOCKER_$(STACK)),-var with_docker=$(WITH_DOCKER_$(STACK)),)

help:
	@echo "tart-stacks — common commands"
	@echo ""
	@echo "  make setup                   Install host tools onto your Mac (run once): symlinks all commands + completions,"
	@echo "                               adds the SSH Include and scaffolds the forwards + mounts config"
	@echo "  make test                    Run the test suite (test/*.sh)"
	@echo "  make list-stacks             List available stacks"
	@echo "  make scaffold STACK=<name>   Create a new stack from templates/stack/"
	@echo "  make init                    Install the Packer plugin (run once)"
	@echo "  make build STACK=<name>      Bootstrap + build the stack image"
	@echo "  make rebuild STACK=<name>    Force-rebuild — overwrites existing image"
	@echo "  make clean                   Remove Packer build artifacts"
	@echo ""
	@echo "Pin a Fedora tag: FEDORA_TAG=42 make bootstrap (otherwise tracks :latest)"

list-stacks:
	@ls -1 stacks 2>/dev/null | sed 's/^fedora-/  /' || echo "  (none)"

# Host-side install (macOS). Idempotent; safe to re-run. Logic lives in
# script/setup so the SSH-config validation stays testable.
setup:
	@"$(CURDIR)/script/setup"

# Run the plain-bash test suite (test/*.sh). No framework; needs only bash + jq.
test:
	@"$(CURDIR)/script/test"

# Validate that STACK is set and the requested stack directory exists.
# build/rebuild depend on this.
check-stack:
	@if [ -z "$(STACK)" ]; then \
		echo "ERROR: STACK is required (e.g., make build STACK=php). Available stacks:" >&2; \
		ls -1 stacks 2>/dev/null | sed 's/^fedora-/  /' >&2 || echo "  (none)" >&2; \
		exit 1; \
	fi
	@if [ ! -d "$(STACK_DIR)" ]; then \
		echo "ERROR: stack '$(STACK)' not found at $(STACK_DIR)/. Available stacks:" >&2; \
		ls -1 stacks 2>/dev/null | sed 's/^fedora-/  /' >&2 || echo "  (none)" >&2; \
		exit 1; \
	fi

# Like check-stack but for a NEW stack: STACK must be set; the dir must NOT exist.
check-stack-name:
	@if [ -z "$(STACK)" ]; then \
		echo "ERROR: STACK is required (e.g., make scaffold STACK=python)." >&2; \
		exit 1; \
	fi

# Install the Packer plugin for the single parameterized root template (run once,
# stack-agnostic).
init:
	@command -v packer >/dev/null 2>&1 || { echo "packer not installed. Run: brew install hashicorp/tap/packer"; exit 1; }
	packer init .

bootstrap:
	@command -v tart >/dev/null 2>&1 || { echo "tart not installed. Run: brew install cirruslabs/cli/tart"; exit 1; }
	tart pull ghcr.io/cirruslabs/fedora:$(FEDORA_TAG)
	-tart delete $(TART_BASE_NAME) 2>/dev/null
	tart clone ghcr.io/cirruslabs/fedora:$(FEDORA_TAG) $(TART_BASE_NAME)

# Build a stack from the one parameterized template, run from the repo root so
# the provisioner script paths (shared/…, stacks/fedora-$(STACK)/…) resolve.
build: check-stack bootstrap
	packer build -var stack=$(STACK) $(DOCKER_VAR) stack.pkr.hcl

rebuild: check-stack bootstrap
	packer build -force -var stack=$(STACK) $(DOCKER_VAR) stack.pkr.hcl

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
	@echo "  1. edit $(STACK_DIR)/files/mise.toml (tool versions) + scripts/mise-install.sh (smoke test)"
	@echo "  2. make build STACK=$(STACK)"
	@echo "  3. add a row to the stack table in README.md"

# Clean Packer artifacts at the repo root and inside every stack directory
# (packer creates these next to the cwd / .pkr.hcl it was invoked from).
clean:
	rm -rf packer_cache/ output-*/ *.log crash.log
	@for d in stacks/*/; do \
		rm -rf "$$d"packer_cache "$$d"output-* "$$d"*.log "$$d"crash.log 2>/dev/null || true; \
	done
