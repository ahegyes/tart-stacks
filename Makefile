SHELL := /bin/bash
.PHONY: help setup uninstall test smoke init bootstrap build rebuild scaffold clean check-stack check-stack-token list-stacks check-distro check-gui check-de

# Stack selector. Required for build/rebuild/scaffold. e.g. `make build STACK=php DISTRO=fedora`.
STACK ?=

# Distro selector. Required for build/rebuild/bootstrap. Must be a line in shared/distros.
DISTRO ?=

# GUI flavor. Optional: GUI=1 bakes the desktop layer (shared/scripts/gui.sh)
# and names the image <distro>-<stack>-<de>; DE picks the desktop (a line in
# shared/desktops). e.g. `make build STACK=php DISTRO=fedora GUI=1 DE=kde`.
# Strictly literal — check-gui rejects every other non-empty value: make
# truthiness would read GUI=0 as ON, and an exported GUI in the caller's
# environment must not silently flip a 40-min build either way.
GUI ?=
DE ?= kde

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
	@echo "  make smoke STACK=<name> DISTRO=<distro>   Smoke-test a BUILT image end-to-end: clone, boot a real VM (~1 min), ssh, assert, destroy. Local-only — never run in CI. GUI=1 [DE=<de>] smokes the GUI flavor"
	@echo "  make clean                                Remove Packer build artifacts"
	@echo ""
	@echo "  DISTRO — required distro token (e.g. fedora). Must be listed in shared/distros."
	@echo "  IMAGE_TAG — override the base image tag (default: latest). e.g. IMAGE_TAG=42 make bootstrap DISTRO=fedora"
	@echo "  GUI=1 — bake the desktop layer into build/rebuild (strictly 1 or unset); the image becomes <distro>-<stack>-<de>. See shared/gui/README.md"
	@echo "  DE — desktop for GUI=1 (default: kde). Must be listed in shared/desktops. e.g. make build STACK=php DISTRO=fedora GUI=1 DE=xfce"

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

# STACK is set and is a bare lowercase-alphanumeric token — the shared gate
# behind check-stack (an existing stack) and scaffold (a new one). The token
# rule is load-bearing for scaffold, which interpolates STACK into mkdir paths
# and a sed replacement: a '/' or '&' would mkdir a nested tree or corrupt every
# stamped file, and the half-scaffolded dir then blocks reruns and gets
# discovered by CI as a stack. build needs it too — `STACK=.` satisfies the
# directory test below and reaches bootstrap's destructive base re-clone before
# Packer rejects the token.
check-stack-token:
	@if [ -z "$(STACK)" ]; then \
		echo "ERROR: STACK is required (e.g., make build STACK=php DISTRO=fedora, make scaffold STACK=python). Available stacks:" >&2; \
		ls -1 stacks 2>/dev/null | sed 's/^/  /' >&2 || echo "  (none)" >&2; \
		exit 1; \
	fi
	@if ! printf '%s\n' "$(STACK)" | grep -qE '^[a-z0-9]+$$'; then \
		echo "ERROR: STACK must be a lowercase alphanumeric token, got '$(STACK)' (e.g., make build STACK=php DISTRO=fedora)." >&2; \
		exit 1; \
	fi

# The requested stack directory exists. build/rebuild/smoke depend on this.
check-stack: check-stack-token
	@if [ ! -d "$(STACK_DIR)" ]; then \
		echo "ERROR: stack '$(STACK)' not found at $(STACK_DIR)/. Available stacks:" >&2; \
		ls -1 stacks 2>/dev/null | sed 's/^/  /' >&2 || echo "  (none)" >&2; \
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

# GUI is 1 or unset — nothing else. Guards the $(if $(GUI),…) truthiness the
# GUI-aware targets key off (see the GUI comment at the top).
check-gui:
	@case "$(GUI)" in ''|1) ;; *) \
		echo "ERROR: GUI must be 1 (bake/select the desktop layer) or unset, got '$(GUI)'." >&2; \
		exit 1 ;; \
	esac

# Validate DE is supported (a non-comment line in shared/desktops) — but only
# when GUI is set: DE is meaningless for headless targets, and `DE ?=` picks
# up the caller's environment, so an irrelevant stray value must not fail a
# headless build/smoke.
check-de:
	@if [ -n "$(GUI)" ] && ! grep -qxF "$(DE)" <(grep -vE '^\s*(#|$$)' shared/desktops); then \
		echo "ERROR: desktop '$(DE)' is not supported. Add it to shared/desktops (and branches in gui-lib.sh) first. Supported:" >&2; \
		grep -vE '^\s*(#|$$)' shared/desktops | sed 's/^/  /' >&2; \
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
# GUI is folded to packer's bool: any non-empty value means true. `de` rides
# along only with GUI — headless builds must not depend on (or trip over) a
# DE value leaked from the environment.
PACKER_VARS = -var stack=$(STACK) -var distro=$(DISTRO) $(if $(GUI),-var gui=true -var de=$(DE),-var gui=false)

# bootstrap runs from the RECIPE, not the prerequisite list: recipe lines only
# start after every check- prerequisite has passed, even under `make -j`,
# whereas sibling prerequisites run in parallel — a rejected invocation must
# never reach bootstrap's destructive base re-clone (tart delete + clone).
build: check-stack check-distro check-gui check-de
	@$(MAKE) bootstrap
	packer build $(PACKER_VARS) stack.pkr.hcl

rebuild: check-stack check-distro check-gui check-de
	@$(MAKE) bootstrap
	packer build -force $(PACKER_VARS) stack.pkr.hcl

# End-to-end proof of a BUILT image (clone → boot → ssh → assert → destroy).
# Boots a real VM, so it stays a local dev-task — GitHub runners can't run
# Tart VMs (no nested virtualization), hence deliberately absent from CI.
# GUI=1 smokes the flavor image (<distro>-<stack>-<de>) instead.
smoke: check-stack check-distro check-gui check-de
	@"$(CURDIR)/script/smoke" "$(STACK)" "$(DISTRO)" $(if $(GUI),"$(DE)")

# Scaffold a new stack from templates/stack/ (substitutes __STACK__). Refuses to
# clobber an existing dir; the root template + dynamic CI then cover it with no
# further wiring.
scaffold: check-stack-token
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
