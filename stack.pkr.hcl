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

# One parameterized template builds every stack: `packer build -var stack=<name> -var distro=<distro>`
# from the repo root (the Makefile runs it there — provisioner script paths
# resolve against the cwd, not this file). The invariant pipeline lives here;
# per-stack content is just stacks/<stack>/{scripts,files}.

variable "stack" {
  type        = string
  description = "Short stack token (php, jvm, …). The built image is <distro>-<stack>, cloned from stacks/<stack>/."
  validation {
    condition     = can(regex("^[a-z0-9]+$", var.stack))
    error_message = "Stack must be a lowercase alphanumeric token such as php or jvm."
  }
}

variable "distro" {
  type        = string
  description = "Distro token (fedora, ubuntu, debian). Mandatory — no default. Must be a line in shared/distros and a branch in distro-lib.sh. The built image is <distro>-<stack>, cloned from <distro>-base."
  validation {
    condition     = can(regex("^[a-z0-9]+$", var.distro))
    error_message = "Distro must be a lowercase alphanumeric token such as fedora, ubuntu, or debian."
  }
}

variable "source_image" {
  type        = string
  description = "Local Tart image to clone as the source. Defaults to <distro>-base, created by `make bootstrap`."
  default     = ""
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

  # source_image defaults to <distro>-base (the make-bootstrap intermediate) unless overridden.
  source_image = var.source_image != "" ? var.source_image : "${var.distro}-base"
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
  vm_name      = "${var.distro}-${var.stack}"
  cpu_count    = var.cpu_count
  memory_gb    = var.memory_gb
  disk_size_gb = var.disk_size_gb
  ssh_username = var.ssh_username
  ssh_password = local.ssh_password
  ssh_timeout  = "10m"
  headless     = true
}

build {
  name    = "${var.distro}-${var.stack}"
  sources = ["source.tart-cli.stack"]

  # Distro abstraction, sourced by every system provisioner — must land before they run.
  provisioner "file" {
    source      = "shared/scripts/distro-lib.sh"
    destination = "/tmp/distro-lib.sh"
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
    execute_command = "echo '${local.ssh_password}' | sudo -S -E bash '{{ .Path }}'"
    scripts = [
      "shared/scripts/00-base.sh",
      "stacks/${var.stack}/scripts/00-stack.sh",
      "shared/scripts/mise.sh",
    ]
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
      "shared/scripts/user-config.sh",
      "shared/scripts/terminfo.sh",
      "shared/scripts/host-keys.sh",
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
    environment_vars  = ["STACK=${var.stack}", "DISTRO=${var.distro}"]
    expect_disconnect = true
    scripts           = ["shared/scripts/99-finalize.sh"]
  }
}
