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

# One parameterized template builds every stack on this platform:
# `packer build -var stack=<name> -var os=<os>` from the repo root (the
# Makefile runs it there — provisioner script paths resolve against the cwd,
# not this file). No `gui`/`de` variable here: the macOS desktop is
# intrinsic, so unlike linux.pkr.hcl this platform has no DE axis.

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
  description = "OS token (macos). Mandatory — no default. Must be a line in shared/darwin/os and the family this platform's family-lib.sh implements (brew). The built image is <os>-<stack>, cloned from <os>-base."
  validation {
    condition     = can(regex("^[a-z0-9]+$", var.os))
    error_message = "OS must be a lowercase alphanumeric token such as macos."
  }
}

variable "ssh_username" {
  type        = string
  description = "SSH user inside the VM. Cirrus Labs Tart images use 'admin' by default."
  default     = "admin"
}

locals {
  # Cirrus Tart images all use this publicly-known default. 99-finalize.sh
  # disables sshd password auth at the end of the build, so cloned VMs only
  # accept SSH key auth (unlike the linux peer, this platform never locks the
  # account password itself — see 99-finalize.sh's `password:` manifest line).
  ssh_password = "admin"

  # The source is <os>-base, the intermediate `make bootstrap` clones from the
  # upstream image — derived, never overridable. An override could name a base from
  # another OS, and since the output name and the provenance manifest both come
  # from var.os, that build would succeed and ship mislabeled.
  source_image = "${var.os}-base"

  # No GUI suffix on this platform — see the variable block comment above.
  vm_name = "${var.os}-${var.stack}"
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
  # The macOS base is ~50 GB before a stack is added, and the APFS container
  # grows to fill a raised disk_size_gb with no guest-side step needed (no
  # diskutil resizeContainer equivalent, measured) — unlike linux's ext4/xfs,
  # which is why this default sits well above the linux templates' 30.
  default = 80
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

  # Package-family abstraction, sourced by 00-base.sh, 00-stack.sh, and
  # 99-finalize.sh — must land before any of them run. No reboot on this
  # platform (Cirrus publishes the macOS base already at the target release,
  # so there is no release-upgrade step), so unlike linux.pkr.hcl's doubled
  # family-lib.sh upload, ONE upload of each library here is correct — /tmp
  # is never emptied mid-build.
  provisioner "file" {
    source      = "shared/darwin/scripts/family-lib.sh"
    destination = "/tmp/family-lib.sh"
  }

  # Per-stack, brew-family package list, read by 00-stack.sh — must land before
  # the root block below, since 00-stack.sh runs inside it immediately after
  # 00-base.sh.
  provisioner "file" {
    source      = "stacks/${var.stack}/packages.brew"
    destination = "/tmp/packages.brew"
  }

  # System-level provisioning (runs as root via sudo). 00-base.sh asserts the
  # guest is what this build claims and brings brew + core tooling up to
  # date; 00-stack.sh installs the stack's native build deps from the upload
  # above. One root provisioner block keeps the package-manager transaction
  # sequence unambiguous, same contract as linux.pkr.hcl.
  provisioner "shell" {
    # {{ .Vars }} is required for environment_vars to reach the script at all;
    # 00-base.sh asserts the guest it landed in is the OS this build claims.
    execute_command  = "echo '${local.ssh_password}' | {{ .Vars }} sudo -S -E bash '{{ .Path }}'"
    environment_vars = ["OS=${var.os}"]
    scripts = [
      "shared/darwin/scripts/00-base.sh",
      "stacks/${var.stack}/scripts/00-stack.sh",
    ]
  }

  # Drop in config files.
  provisioner "file" {
    source      = "shared/files/zshrc"
    destination = "/Users/${var.ssh_username}/.zshrc"
  }

  provisioner "file" {
    source      = "stacks/${var.stack}/files/mise.toml"
    destination = "/Users/${var.ssh_username}/.config/mise/config.toml"
  }

  # Shared mise helpers, sourced by the stack's darwin/mise-install.sh below
  # (uploaded rather than added to a scripts=[] block, which would run it in
  # its own shell).
  provisioner "file" {
    source      = "shared/scripts/mise-lib.sh"
    destination = "/tmp/mise-lib.sh"
  }

  # Anti-lockout gate for the SSH key uploaded below, sourced by 99-finalize.sh
  # before it authorizes that key.
  provisioner "file" {
    source      = "shared/scripts/authorized-key-lib.sh"
    destination = "/tmp/authorized-key-lib.sh"
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

  # System-level config requiring root + the uploaded files above: PATH
  # activation, the /mnt/shared parity link for Tart --dir shares, the
  # forwarded-agent runtime dir, and the vendored terminfo (xterm-ghostty,
  # which ncurses-term lacks). No host-keys.sh peer on this platform — macOS
  # regenerates its own host keys via sshd-keygen-wrapper on first connect
  # (see 99-finalize.sh, which deletes the base's keys so each clone mints
  # its own with no unit and no marker file needed).
  provisioner "shell" {
    execute_command = "echo '${local.ssh_password}' | sudo -S -E bash '{{ .Path }}'"
    scripts = [
      "shared/darwin/scripts/user-config.sh",
      "shared/scripts/terminfo.sh",
    ]
  }

  # Install language runtimes per the uploaded mise.toml (user-level).
  # Runs before final lockdown because it needs mise.toml uploaded and the
  # build user still SSH-able with the provisioning password.
  provisioner "shell" {
    scripts = ["stacks/${var.stack}/scripts/darwin/mise-install.sh"]
  }

  # Final lockdown — runs LAST. 99-finalize.sh authorizes the user SSH key,
  # disables the base's remote-access services (Screen Sharing, Kerberos
  # KDC), and writes the sshd drop-in disabling password auth. Packer
  # disconnects right after.
  provisioner "shell" {
    # {{ .Vars }} is where Packer renders environment_vars as KEY='v' shell
    # prefixes — a custom execute_command that omits it gets NO env vars at
    # all. They prefix sudo, and -E carries them into the script.
    execute_command   = "echo '${local.ssh_password}' | {{ .Vars }} sudo -S -E bash '{{ .Path }}'"
    # The provenance manifest names the cell it was built as.
    environment_vars  = ["STACK=${var.stack}", "OS=${var.os}"]
    expect_disconnect = true
    scripts           = ["shared/darwin/scripts/99-finalize.sh"]
  }
}
