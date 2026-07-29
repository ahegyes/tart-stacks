SHELL := /bin/bash
.PHONY: help setup uninstall test lint smoke init bootstrap build rebuild scaffold clean check-stack check-stack-token list-stacks check-os check-gui check-de

# Stack selector. Required for build/rebuild/scaffold. e.g. `make build STACK=php OS=fedora`.
STACK ?=

# OS selector. Required for build/rebuild/bootstrap. Must be a line in exactly
# one shared/<platform>/os (check-os), which is also what selects the platform.
OS ?=

# GUI flavor. Optional: GUI=1 bakes the desktop layer (shared/linux/scripts/gui.sh)
# and names the image <os>-<stack>-<de>; DE picks the desktop (a line in
# shared/linux/desktops). e.g. `make build STACK=php OS=fedora GUI=1 DE=kde`.
# Strictly literal — check-gui rejects every other non-empty value: make
# truthiness would read GUI=0 as ON, and an exported GUI in the caller's
# environment must not silently flip a 40-min build either way.
GUI ?=
DE ?= kde

# Override to pin a non-latest base image tag: `IMAGE_TAG=24.04 make bootstrap OS=ubuntu`.
IMAGE_TAG ?= latest

# Intermediate Tart base image (per OS). `bootstrap` clones the Cirrus image
# into <os>-base; the parameterized build clones from it.
TART_BASE_NAME = $(OS)-base

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
	@echo "  make build STACK=<name> OS=<os>           Bootstrap + build the stack image"
	@echo "  make rebuild STACK=<name> OS=<os>         Force-rebuild — overwrites existing image"
	@echo "  make smoke STACK=<name> OS=<os>           Smoke-test a BUILT image end-to-end: clone, boot a real VM (~1 min), guest agent, ssh, assert, destroy. Local-only — never run in CI. GUI=1 [DE=<de>] smokes the GUI flavor"
	@echo "  make clean                                Remove Packer build artifacts"
	@echo ""
	@echo "  OS — required OS token (e.g. fedora, macos). Must be listed in exactly one shared/<platform>/os."
	@echo "  IMAGE_TAG — override the base image tag (default: latest). e.g. IMAGE_TAG=42 make bootstrap OS=fedora"
	@echo "  GUI=1 — bake the desktop layer into build/rebuild (strictly 1 or unset); the image becomes <os>-<stack>-<de>. See shared/linux/gui/README.md"
	@echo "  DE — desktop for GUI=1 (default: kde). Must be listed in shared/linux/desktops. e.g. make build STACK=php OS=fedora GUI=1 DE=xfce"

list-stacks:
	@stacks=$$(ls -1 stacks 2>/dev/null); if [ -n "$$stacks" ]; then echo "$$stacks" | sed 's/^/  /'; else echo "  (none)"; fi

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

# lint — the ONE definition of what shellcheck covers, so the docs and CI
# cannot describe different sets. A `*.sh` glob is not that set: every host
# command (bin/tart-*, script/*) is extensionless, so a glob-based command
# silently skips the most security-relevant files in the repo while
# a whole-repo scan lints them. Discovery here matches what such a scan finds —
# tracked *.sh, plus tracked executables with no extension whose first line is
# a shell shebang. Scaffold templates are linted with __STACK__ substituted,
# since their .tmpl suffix hides them from any name-based match.
lint:
	@files=$$(git ls-files '*.sh'); \
	for f in $$(git ls-files); do \
	  case "$$f" in *.*) continue ;; esac; \
	  [ -f "$$f" ] && [ -x "$$f" ] || continue; \
	  if head -n1 "$$f" | grep -qE '^#! */[^ ]*/(env +)?[abk]*sh'; then files="$$files $$f"; fi; \
	done; \
	n=$$(printf '%s\n' $$files | grep -c .); \
	echo "==> shellcheck: $$n tracked scripts"; \
	shellcheck -f gcc $$files || exit 1; \
	for t in templates/stack/scripts/*.sh.tmpl templates/stack/scripts/*/*.sh.tmpl; do \
	  [ -e "$$t" ] || continue; \
	  echo "==> shellcheck: $$t (__STACK__ substituted)"; \
	  sed 's/__STACK__/x/g' "$$t" | shellcheck -f gcc - || exit 1; \
	done; \
	echo "lint: clean"

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
		echo "ERROR: STACK is required (e.g., make build STACK=php OS=fedora, make scaffold STACK=python). Available stacks:" >&2; \
		stacks=$$(ls -1 stacks 2>/dev/null); if [ -n "$$stacks" ]; then echo "$$stacks" | sed 's/^/  /' >&2; else echo "  (none)" >&2; fi; \
		exit 1; \
	fi
	@if ! printf '%s\n' "$(STACK)" | grep -qE '^[a-z0-9]+$$'; then \
		echo "ERROR: STACK must be a lowercase alphanumeric token, got '$(STACK)' (e.g., make build STACK=php OS=fedora)." >&2; \
		exit 1; \
	fi

# The requested stack directory exists. build/rebuild/smoke depend on this.
check-stack: check-stack-token
	@if [ ! -d "$(STACK_DIR)" ]; then \
		echo "ERROR: stack '$(STACK)' not found at $(STACK_DIR)/. Available stacks:" >&2; \
		stacks=$$(ls -1 stacks 2>/dev/null); if [ -n "$$stacks" ]; then echo "$$stacks" | sed 's/^/  /' >&2; else echo "  (none)" >&2; fi; \
		exit 1; \
	fi

# Platform for the selected OS — the directory whose os file lists the
# token. Derived rather than declared: membership is a property of the tree,
# so there is no second list to drift out of sync with shared/*/os. Counts
# every match instead of stopping at the first: the glob is alphabetical, so
# darwin sorts before linux, and silently keeping the first hit would let one
# platform's token shadow another's with no warning — exactly one match
# resolves; zero or more than one both yield empty, since neither is a single
# well-defined platform. (check-os is what turns "more than one" into a loud
# refusal naming the token and every claiming file; this variable only
# refuses to guess.) `:=` (not `=`) so it's computed once, from OS's final
# value, and `make -p` shows the resolved platform rather than this unexpanded
# shell text — the `#` inside the regex must stay escaped (`\#`), since
# outside a recipe make treats a bare `#` as the start of a make comment and
# truncates the line.
PLATFORM := $(shell count=0; chosen=""; \
	for f in shared/*/os; do \
	  grep -qxF "$(OS)" <(grep -vE '^[[:space:]]*(\#|$$)' "$$f") \
	    && count=$$((count + 1)) && chosen="$$f"; \
	done; \
	[ "$$count" -eq 1 ] && basename "$$(dirname "$$chosen")")

# Validate OS is set, supported, and claimed by exactly one platform. Scans
# every shared/*/os rather than hardcoding shared/linux/os, so a new
# platform's token list is picked up by construction rather than a second
# edit here — this gate and the PLATFORM resolver above are two readers of the
# same tree, and a hardcoded list in either one drifts from it. The
# "Supported:" listing groups tokens
# under the platform that claims them: a flattened "macos fedora ubuntu"
# gives a reader no way to route a token back to a directory.
check-os:
	@if [ -z "$(OS)" ]; then \
		echo "ERROR: OS is required (e.g., make build STACK=php OS=fedora). Supported:" >&2; \
		for f in shared/*/os; do \
			echo "  $$(basename "$$(dirname "$$f")"):" >&2; \
			grep -vE '^\s*(#|$$)' "$$f" | sed 's/^/    /' >&2; \
		done; \
		exit 1; \
	fi
	@count=0; claimants=""; \
	for f in shared/*/os; do \
		if grep -qxF "$(OS)" <(grep -vE '^\s*(#|$$)' "$$f"); then \
			count=$$((count + 1)); \
			claimants="$$claimants $$f"; \
		fi; \
	done; \
	if [ "$$count" -eq 0 ]; then \
		echo "ERROR: OS '$(OS)' is not supported. Add it to the right platform's shared/<platform>/os (and a family branch) first. Supported:" >&2; \
		for f in shared/*/os; do \
			echo "  $$(basename "$$(dirname "$$f")"):" >&2; \
			grep -vE '^\s*(#|$$)' "$$f" | sed 's/^/    /' >&2; \
		done; \
		exit 1; \
	fi; \
	if [ "$$count" -gt 1 ]; then \
		echo "ERROR: OS '$(OS)' is claimed by more than one platform —$$claimants — refusing rather than silently building whichever shared/*/os the glob lists first. Remove it from all but one file." >&2; \
		exit 1; \
	fi
	@if [ -z "$(PLATFORM)" ]; then \
		echo "ERROR: OS '$(OS)' passed the checks above but resolved to no platform — this means the checks above and the PLATFORM resolver have drifted out of sync." >&2; \
		exit 1; \
	fi

# GUI is 1 or unset — nothing else. Guards the $(if $(GUI),…) truthiness the
# GUI-aware targets key off (see the GUI comment at the top). Darwin gets a
# second refusal below: the macOS desktop is intrinsic to the base image, so
# the platform has no DE axis for GUI=1 to bake — GUI=1 is a linux-only flag.
check-gui:
	@case "$(GUI)" in ''|1) ;; *) \
		echo "ERROR: GUI must be 1 (bake/select the desktop layer) or unset, got '$(GUI)'." >&2; \
		exit 1 ;; \
	esac
	@if [ -n "$(GUI)" ] && [ "$(PLATFORM)" = "darwin" ]; then \
		echo "ERROR: GUI=1 is a linux-platform flag. The macOS desktop is intrinsic, so darwin images have no DE axis and are named <os>-<stack> with no -<de> suffix. Use 'tart-up --gui=window' (or vnc) on the clone instead." >&2; \
		exit 1; \
	fi

# Validate DE is supported (a non-comment line in shared/linux/desktops) — but only
# when GUI is set: DE is meaningless for headless targets, and `DE ?=` picks
# up the caller's environment, so an irrelevant stray value must not fail a
# headless build/smoke.
check-de:
	@if [ -n "$(GUI)" ] && ! grep -qxF "$(DE)" <(grep -vE '^\s*(#|$$)' shared/linux/desktops); then \
		echo "ERROR: desktop '$(DE)' is not supported. Add it to shared/linux/desktops (and branches in gui-lib.sh) first. Supported:" >&2; \
		grep -vE '^\s*(#|$$)' shared/linux/desktops | sed 's/^/  /' >&2; \
		exit 1; \
	fi

# Install the Packer plugin for every platform's root template (run once,
# stack-agnostic). One `packer init` per *.pkr.hcl, not a single directory-wide
# `packer init .`: every root template declares the same top-level stack/os/
# ssh_username variables (each inits clean alone), and a directory-wide init
# parses every *.pkr.hcl together and refuses on the resulting duplicate
# variable/local definitions. The glob, not a hand-maintained platform list,
# is what this loop iterates — linux.pkr.hcl and darwin.pkr.hcl are co-equal
# root templates (see the tree layout above), so a third platform's template
# is picked up here the same way it already is by PLATFORM (:107) and CI's
# discover job, with no second list to drift out of sync.
init:
	@command -v packer >/dev/null 2>&1 || { echo "packer not installed. Run: brew install hashicorp/tap/packer"; exit 1; }
	@for f in *.pkr.hcl; do \
		echo "==> packer init $$f"; \
		packer init "$$f" || exit 1; \
	done

# Upstream base image for the selected OS. The linux images are published as
# ghcr.io/cirruslabs/<os>, keyed directly off the OS token, but Cirrus
# publishes macOS per release rather than under a rolling name (macos-tahoe-base,
# macos-sequoia-base, …), so darwin can't derive its image from $(OS) the way
# linux does — MACOS_RELEASE names the release here instead. Bumping it is
# editing this line and rebuilding — unlike FEDORA_TARGET_RELEASE, which
# pkg_release_upgrade actively drives the guest to, this only selects which
# Cirrus base gets pulled; shared/darwin/scripts/family-lib.sh's
# MACOS_TARGET_RELEASE is a separate floor (`-ge`, not an equality check), so
# raising MACOS_RELEASE without also raising that floor builds silently on the
# newer release rather than failing.
# `:=`, not `=`: PLATFORM above is itself `:=` (fixed once OS is known), and a
# recursively-expanded BASE_IMAGE would otherwise re-evaluate this $(if …) on
# every reference instead of settling once alongside it.
MACOS_RELEASE ?= tahoe
BASE_IMAGE := $(if $(filter darwin,$(PLATFORM)),ghcr.io/cirruslabs/macos-$(MACOS_RELEASE)-base:$(IMAGE_TAG),ghcr.io/cirruslabs/$(OS):$(IMAGE_TAG))

bootstrap: check-os
	@command -v tart >/dev/null 2>&1 || { echo "tart not installed. Run: brew install openai/tools/tart"; exit 1; }
	tart pull $(BASE_IMAGE)
	-tart delete $(TART_BASE_NAME) 2>/dev/null
	tart clone $(BASE_IMAGE) $(TART_BASE_NAME)

# Build a stack from the one parameterized template, run from the repo root so
# the provisioner script paths (shared/…, stacks/<stack>/…) resolve.
# GUI is folded to packer's bool: any non-empty value means true. `de` rides
# along only with GUI — headless builds must not depend on (or trip over) a
# DE value leaked from the environment. Gated on PLATFORM=linux: darwin.pkr.hcl
# declares no gui/de variable at all (the macOS desktop is intrinsic), and
# Packer hard-errors on an undeclared -var — check-gui already refuses GUI=1
# on darwin, so the gate here only has to drop the unconditional -var gui=false
# that would otherwise reach that template on every darwin build.
PACKER_VARS = -var stack=$(STACK) -var os=$(OS) $(if $(filter linux,$(PLATFORM)),$(if $(GUI),-var gui=true -var de=$(DE),-var gui=false))

# bootstrap runs from the RECIPE, not the prerequisite list: recipe lines only
# start after every check- prerequisite has passed, even under `make -j`,
# whereas sibling prerequisites run in parallel — a rejected invocation must
# never reach bootstrap's destructive base re-clone (tart delete + clone).
build: check-stack check-os check-gui check-de
	@$(MAKE) bootstrap
	packer build $(PACKER_VARS) $(PLATFORM).pkr.hcl

rebuild: check-stack check-os check-gui check-de
	@$(MAKE) bootstrap
	packer build -force $(PACKER_VARS) $(PLATFORM).pkr.hcl

# End-to-end proof of a BUILT image (clone → boot → ssh → assert → destroy).
# Boots a real VM, so it stays a local dev-task — GitHub runners can't run
# Tart VMs (no nested virtualization), hence deliberately absent from CI.
# GUI=1 smokes the flavor image (<os>-<stack>-<de>) instead.
smoke: check-stack check-os check-gui check-de
	@"$(CURDIR)/script/smoke" "$(STACK)" "$(OS)" $(if $(GUI),"$(DE)")

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
	@chmod +x "$(STACK_DIR)"/scripts/*.sh "$(STACK_DIR)"/scripts/*/*.sh
	@echo "scaffolded $(STACK_DIR)/ — next:"
	@echo "  1. edit $(STACK_DIR)/files/mise.toml (tool versions) and $(STACK_DIR)/tools"
	@echo "     (one row per tool — script/smoke runs each row's proof at runtime)"
	@echo "  2. in scripts/linux/mise-install.sh AND scripts/darwin/mise-install.sh, add"
	@echo "     ONE smoke_gate group per tool row — make test holds the gate calls to"
	@echo "     set equality with the tools file, so a missing group (or an undeclared"
	@echo "     one) fails the suite; the two files start identical, so keep them in"
	@echo "     sync unless a runtime needs a platform-specific flag"
	@echo "  3. make build STACK=$(STACK) OS=<os>"
	@echo "  4. add a row to the stack table in README.md"

# Clean Packer artifacts at the repo root and inside every stack directory
# (packer creates these next to the cwd / .pkr.hcl it was invoked from).
clean:
	rm -rf packer_cache/ output-*/ *.log crash.log
	@for d in stacks/*/; do \
		rm -rf "$$d"packer_cache "$$d"output-* "$$d"*.log "$$d"crash.log 2>/dev/null || true; \
	done
