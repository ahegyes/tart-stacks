packer {
  required_plugins {
    tart = {
      # Float within 1.x, but cap below 2.0: a new major could break the build and
      # Dependabot has no Packer-plugin ecosystem to flag it. Raise the ceiling
      # deliberately after testing a 2.0 release.
      version = ">= 1.20.0, < 2.0.0"
      source  = "github.com/cirruslabs/tart"
    }
  }
}

# One parameterized template builds every stack: `packer build -var stack=<name> -var os=<os>`
# from the repo root (the Makefile runs it there — provisioner script paths
# resolve against the cwd, not this file). The invariant pipeline lives here;
# per-stack content is just stacks/<stack>/{scripts,files}.

variable "stack" {
  type        = string
  description = "Short stack token (php, jvm, …). The built image is <os>-<stack>, cloned from stacks/<stack>/."
  validation {
    condition     = can(regex("^[a-z0-9]+$", var.stack))
    error_message = "Stack must be a lowercase alphanumeric token such as php or jvm."
  }
}

variable "os" {
  type        = string
  description = "OS token (fedora, ubuntu, debian). Mandatory — no default. Must be a line in shared/linux/os and a branch in family-lib.sh. The built image is <os>-<stack>, cloned from <os>-base."
  validation {
    condition     = can(regex("^[a-z0-9]+$", var.os))
    error_message = "OS must be a lowercase alphanumeric token such as fedora, ubuntu, or debian."
  }
}

variable "gui" {
  type        = bool
  default     = false
  description = "Bake the optional desktop layer (shared/linux/scripts/gui.sh): a desktop environment, display manager, and a localhost-only VNC server. The built image is <os>-<stack>-<de>. Boot contract in shared/linux/gui/README.md."
}

variable "de" {
  type        = string
  default     = "kde"
  description = "Desktop environment for gui=true. Ignored when gui=false. Must be a line in shared/linux/desktops and a branch in gui-lib.sh (kde, gnome, xfce)."
  validation {
    condition     = can(regex("^[a-z0-9]+$", var.de))
    error_message = "DE must be a lowercase alphanumeric token such as kde, gnome, or xfce."
  }
}

variable "ssh_username" {
  type        = string
  description = "SSH user inside the VM. Cirrus Labs Tart images use 'admin' by default."
  default     = "admin"
}

locals {
  # Cirrus Tart images all use this publicly-known default. 99-finalize.sh
  # locks the password at the end of the build, so cloned VMs only accept SSH
  # key auth.
  ssh_password = "admin"

  # The source is <os>-base, the intermediate `make bootstrap` clones from the
  # upstream image — derived, never overridable. An override could name a base from
  # another OS, and since the output name and the provenance manifest both come
  # from var.os, that build would succeed and ship mislabeled.
  source_image = "${var.os}-base"

  # The -<de> suffix keeps GUI flavors distinguishable (and side-by-side
  # buildable) in `tart list`; the provenance manifest records the same fact
  # as its `gui:` line.
  vm_name = var.gui ? "${var.os}-${var.stack}-${var.de}" : "${var.os}-${var.stack}"
}

variable "ssh_pubkey_path" {
  type        = string
  description = "Path to the public SSH key authorized for Mac → VM access. A dedicated Secure-Enclave-backed key managed by Secretive. Must exist before `make build` — see top-level README for setup."
  default     = "~/.ssh/tart-vm.pub"
}

variable "cpu_count" {
  type    = number
  default = 4
}

variable "memory_gb" {
  type    = number
  default = 8
}

variable "disk_size_gb" {
  type    = number
  default = 30
}

source "tart-cli" "stack" {
  vm_base_name = local.source_image
  vm_name      = local.vm_name
  cpu_count    = var.cpu_count
  memory_gb    = var.memory_gb
  disk_size_gb = var.disk_size_gb
  ssh_username = var.ssh_username
  ssh_password = local.ssh_password
  ssh_timeout  = "10m"
  headless     = true
}

build {
  name    = local.vm_name
  sources = ["source.tart-cli.stack"]

  # Staged for the release upgrade below, which is the only thing that reads it
  # before the reboot. Nothing else may be uploaded ahead of that block.
  provisioner "file" {
    source      = "shared/linux/scripts/family-lib.sh"
    destination = "/tmp/family-lib.sh"
  }

  # Release upgrade — the first thing run in the guest, before anything is
  # installed on it. It leads because 00-base.sh's first act is a full system
  # update, and updating a release that is about to be replaced downloads a set of
  # packages the upgrade then discards.
  #
  # Inline rather than a script file: the body is glue. Every decision it could
  # encode — which release, the two-release ceiling, the apt no-op, the unknown
  # family — lives in family-lib.sh's pkg_release_upgrade, where it is tested.
  #
  # ALONE IN THIS BLOCK, AND NOTHING MAY FOLLOW IT. pkg_release_upgrade reboots
  # the guest and never returns: `dnf offline reboot` only SCHEDULES the reboot,
  # so it blocks until the guest goes down, and that dying SSH session is the only
  # signal expect_disconnect can act on. Add provisioners here and they simply
  # never run. Put expect_disconnect on a block that also installs packages and a
  # guest dying mid-install gets swallowed instead of failing the build.
  #
  # No pause_before on what comes after: the SSH communicator blocks until the
  # guest is reachable again, so a fixed wait would only add dead time and a
  # constant to keep tuned.
  provisioner "shell" {
    execute_command   = "echo '${local.ssh_password}' | sudo -S -E bash '{{ .Path }}'"
    expect_disconnect = true
    inline = [
      "set -euo pipefail",
      "source /tmp/family-lib.sh",
      "pkg_release_upgrade",
    ]
  }

  # ─────────────────────────────────────────────────────────────────────────────
  # EVERY upload below this line must STAY below it. The reboot above empties
  # /tmp, so anything staged earlier is gone before a provisioner can read it —
  # a build that gets this wrong dies at 00-base.sh with a missing family-lib.sh.
  # That is why family-lib.sh is uploaded twice: the copy above serves the
  # upgrade, this one serves everything after the reboot.
  # ─────────────────────────────────────────────────────────────────────────────

  # Package-family abstraction, sourced by every system provisioner — must land before they run.
  provisioner "file" {
    source      = "shared/linux/scripts/family-lib.sh"
    destination = "/tmp/family-lib.sh"
  }

  # DE × family abstraction for the optional GUI layer, sourced by gui.sh.
  # Uploaded unconditionally (Packer provisioners have no per-block condition);
  # gui.sh no-ops when GUI=false.
  provisioner "file" {
    source      = "shared/linux/scripts/gui-lib.sh"
    destination = "/tmp/gui-lib.sh"
  }

  # Per-user desktop scale editor installed by gui.sh with this image's DE
  # and build account baked in. Uploaded unconditionally for gui=false parity.
  provisioner "file" {
    source      = "shared/linux/scripts/display-scale.sh"
    destination = "/tmp/display-scale.sh"
  }

  # Plasma default-panel launcher pinning, run by gui.sh for the kde DE only.
  # Standalone so its template transform is testable without a desktop.
  provisioner "file" {
    source      = "shared/linux/scripts/kde-panel.sh"
    destination = "/tmp/kde-panel.sh"
  }

  # Per-stack, per-family package lists, read by 00-stack.sh.
  provisioner "file" {
    source      = "stacks/${var.stack}/packages.dnf"
    destination = "/tmp/packages.dnf"
  }

  provisioner "file" {
    source      = "stacks/${var.stack}/packages.apt"
    destination = "/tmp/packages.apt"
  }

  # System-level provisioning (runs as root via sudo). Shared base first, then
  # the stack's package hook, then mise. One root provisioner block keeps the
  # package-manager transaction sequence unambiguous.
  provisioner "shell" {
    # {{ .Vars }} is required for environment_vars to reach the script at all;
    # 00-base.sh asserts the guest it landed in is the OS this build claims.
    execute_command  = "echo '${local.ssh_password}' | {{ .Vars }} sudo -S -E bash '{{ .Path }}'"
    environment_vars = ["OS=${var.os}"]
    scripts = [
      "shared/linux/scripts/00-base.sh",
      "stacks/${var.stack}/scripts/00-stack.sh",
      "shared/linux/scripts/mise.sh",
    ]
  }

  # Optional desktop layer — desktop environment + display manager + a
  # localhost-only VNC session service (contract: shared/linux/gui/README.md).
  # Its own root block because it needs GUI/DE as environment_vars, which
  # {{ .Vars }} renders; exits immediately when GUI=false.
  provisioner "shell" {
    execute_command  = "echo '${local.ssh_password}' | {{ .Vars }} sudo -S -E bash '{{ .Path }}'"
    environment_vars = ["GUI=${var.gui}", "DE=${var.de}"]
    scripts          = ["shared/linux/scripts/gui.sh"]
  }

  # Drop in config files.
  provisioner "file" {
    source      = "shared/files/zshrc"
    destination = "/home/${var.ssh_username}/.zshrc"
  }

  provisioner "file" {
    source      = "stacks/${var.stack}/files/mise.toml"
    destination = "/home/${var.ssh_username}/.config/mise/config.toml"
  }

  # Shared mise helpers, sourced by the stack's mise-install.sh below (uploaded
  # rather than added to a scripts=[] block, which would run it in its own shell).
  provisioner "file" {
    source      = "shared/scripts/mise-lib.sh"
    destination = "/tmp/mise-lib.sh"
  }

  # Upload the host's public SSH key (consumed by 99-finalize.sh).
  provisioner "file" {
    source      = pathexpand(var.ssh_pubkey_path)
    destination = "/tmp/authorized_key.pub"
  }

  # Vendored terminfo, compiled by terminfo.sh below (ncurses-term omits xterm-ghostty).
  provisioner "file" {
    source      = "shared/files/xterm-ghostty.terminfo"
    destination = "/tmp/xterm-ghostty.terminfo"
  }

  # System-level config requiring root + the uploaded files: user shell/PATH,
  # the vendored terminfo (xterm-ghostty, which ncurses-term lacks), and the
  # first-boot host-key oneshot every clone triggers before its sshd starts.
  provisioner "shell" {
    execute_command = "echo '${local.ssh_password}' | sudo -S -E bash '{{ .Path }}'"
    scripts = [
      "shared/linux/scripts/user-config.sh",
      "shared/scripts/terminfo.sh",
      "shared/linux/scripts/host-keys.sh",
    ]
  }

  # Install language runtimes per the uploaded mise.toml (user-level).
  # Runs before final lockdown because it needs mise.toml uploaded and the
  # build user still SSH-able with the provisioning password.
  provisioner "shell" {
    scripts = ["stacks/${var.stack}/scripts/mise-install.sh"]
  }

  # Final lockdown — runs LAST as a single atomic step. 99-finalize.sh
  # authorizes the user SSH key, installs NOPASSWD sudoers, writes the sshd
  # drop-in disabling password auth, and locks the admin password. Bundling
  # makes the "no provisioner between disabling password auth and Packer
  # disconnecting" constraint structural. Packer disconnects right after.
  provisioner "shell" {
    # {{ .Vars }} is where Packer renders environment_vars as KEY='v' shell
    # prefixes — a custom execute_command that omits it gets NO env vars at
    # all. They prefix sudo, and -E carries them into the script.
    execute_command   = "echo '${local.ssh_password}' | {{ .Vars }} sudo -S -E bash '{{ .Path }}'"
    # The provenance manifest names the cell it was built as.
    environment_vars  = ["STACK=${var.stack}", "OS=${var.os}", "GUI=${var.gui}", "DE=${var.de}"]
    expect_disconnect = true
    scripts           = ["shared/linux/scripts/99-finalize.sh"]
  }
}
