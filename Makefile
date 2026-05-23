.PHONY: help init bootstrap build rebuild clean check-stack list-stacks

# Stack selector. Required for init/build/rebuild. e.g. `make build STACK=php`.
# Resolves to stacks/fedora-$(STACK)/.
STACK ?=

# Override to pin a non-latest Fedora tag: `FEDORA_TAG=42 make bootstrap`.
# Cirrus publishes `latest`, `42`, `39`, `38`, but 39/38 ship dnf4 and break
# docker.sh. Effective supported set: `latest`, `42`.
FEDORA_TAG ?= latest

# Intermediate Tart base image (shared across stacks). `bootstrap` clones the
# Cirrus image into this name; each stack's Packer build then clones from it.
TART_BASE_NAME ?= fedora-base

STACK_DIR := stacks/fedora-$(STACK)

help:
	@echo "tart-stacks — common commands"
	@echo ""
	@echo "  make list-stacks             List available stacks"
	@echo "  make init STACK=<name>       Install Packer plugins for that stack (run once per stack)"
	@echo "  make bootstrap               Pull latest Fedora base (stack-agnostic; auto-run by build)"
	@echo "  make build STACK=<name>      Bootstrap + build the stack image"
	@echo "  make rebuild STACK=<name>    Force-rebuild — overwrites existing image"
	@echo "  make clean                   Remove Packer build artifacts"
	@echo ""
	@echo "Pin a Fedora tag: FEDORA_TAG=42 make bootstrap (otherwise tracks :latest)"

list-stacks:
	@ls -1 stacks 2>/dev/null | sed 's/^fedora-/  /' || echo "  (none)"

# Validates that STACK is set and the requested stack directory exists.
# Stack-targeted commands (init/build/rebuild) depend on this.
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

init: check-stack
	@command -v packer >/dev/null 2>&1 || { echo "packer not installed. Run: brew install hashicorp/tap/packer"; exit 1; }
	cd $(STACK_DIR) && packer init .

bootstrap:
	@command -v tart >/dev/null 2>&1 || { echo "tart not installed. Run: brew install cirruslabs/cli/tart"; exit 1; }
	tart pull ghcr.io/cirruslabs/fedora:$(FEDORA_TAG)
	-tart delete $(TART_BASE_NAME) 2>/dev/null
	tart clone ghcr.io/cirruslabs/fedora:$(FEDORA_TAG) $(TART_BASE_NAME)

build: check-stack bootstrap
	cd $(STACK_DIR) && packer build stack.pkr.hcl

rebuild: check-stack bootstrap
	cd $(STACK_DIR) && packer build -force stack.pkr.hcl

# Clean Packer artifacts at the repo root and inside every stack directory
# (packer creates these next to the .pkr.hcl file it was invoked from).
clean:
	rm -rf packer_cache/ output-*/ *.log crash.log
	@for d in stacks/*/; do \
		rm -rf "$$d"packer_cache "$$d"output-* "$$d"*.log "$$d"crash.log 2>/dev/null || true; \
	done
