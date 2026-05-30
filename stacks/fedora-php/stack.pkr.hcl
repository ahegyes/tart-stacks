packer {
  required_plugins {
    tart = {
      version = ">= 1.20.0"
      source  = "github.com/cirruslabs/tart"
    }
  }
}

variable "source_image" {
  type        = string
  description = "Local Tart image to clone as the source. `make bootstrap` creates this from ghcr.io/cirruslabs/fedora:latest."
  default     = "fedora-base"
}

variable "output_name" {
  type        = string
  description = "Name of the resulting Tart image."
  default     = "fedora-php"
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

source "tart-cli" "fedora-php" {
  vm_base_name = var.source_image
  vm_name      = var.output_name
  cpu_count    = var.cpu_count
  memory_gb    = var.memory_gb
  disk_size_gb = var.disk_size_gb
  ssh_username = var.ssh_username
  ssh_password = local.ssh_password
  ssh_timeout  = "10m"
  headless     = true
}

build {
  name    = "fedora-php"
  sources = ["source.tart-cli.fedora-php"]

  # System-level provisioning (runs as root via sudo). Shared base first, then
  # PHP build deps, then Docker, then mise. One root provisioner block keeps the
  # dnf transaction sequence unambiguous.
  provisioner "shell" {
    execute_command = "echo '${local.ssh_password}' | sudo -S -E bash '{{ .Path }}'"
    scripts = [
      "../../shared/scripts/00-base.sh",
      "./scripts/00-stack.sh",
      "../../shared/scripts/docker.sh",
      "../../shared/scripts/mise.sh",
    ]
  }

  # Drop in config files.
  provisioner "file" {
    source      = "../../shared/files/zshrc"
    destination = "/home/${var.ssh_username}/.zshrc"
  }

  provisioner "file" {
    source      = "./files/mise.toml"
    destination = "/home/${var.ssh_username}/.config/mise/config.toml"
  }

  # Upload the host's public SSH key (consumed by 99-finalize.sh).
  provisioner "file" {
    source      = pathexpand(var.ssh_pubkey_path)
    destination = "/tmp/authorized_key.pub"
  }

  # Vendored terminfo, compiled by terminfo.sh below (ncurses-term omits xterm-ghostty).
  provisioner "file" {
    source      = "../../shared/files/xterm-ghostty.terminfo"
    destination = "/tmp/xterm-ghostty.terminfo"
  }

  # System-level config requiring root + the uploaded files: user shell/PATH, then
  # compile the vendored terminfo (xterm-ghostty, which ncurses-term lacks).
  provisioner "shell" {
    execute_command = "echo '${local.ssh_password}' | sudo -S -E bash '{{ .Path }}'"
    scripts = [
      "../../shared/scripts/user-config.sh",
      "../../shared/scripts/terminfo.sh",
    ]
  }

  # Install language runtimes per the uploaded mise.toml (user-level).
  # Runs before final lockdown because it needs mise.toml uploaded and the
  # build user still SSH-able with the provisioning password.
  provisioner "shell" {
    scripts = ["./scripts/mise-install.sh"]
  }

  # Final lockdown — runs LAST as a single atomic step. 99-finalize.sh
  # authorizes the user SSH key, installs NOPASSWD sudoers, writes the sshd
  # drop-in disabling password auth, and locks the admin password. Bundling
  # makes the "no provisioner between disabling password auth and Packer
  # disconnecting" constraint structural. Packer disconnects right after.
  provisioner "shell" {
    execute_command   = "echo '${local.ssh_password}' | sudo -S -E bash '{{ .Path }}'"
    expect_disconnect = true
    scripts           = ["../../shared/scripts/99-finalize.sh"]
  }
}
