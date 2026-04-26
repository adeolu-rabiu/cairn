terraform {
  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "~> 0.76"
    }
  }
}

# ── Provider ────────────────────────────────────────────────────────────────
provider "proxmox" {
  endpoint = var.proxmox_endpoint
  username = "root@pam"
  password = var.proxmox_password
  insecure = true
}

# ── Variables ────────────────────────────────────────────────────────────────
variable "proxmox_endpoint" {
  description = "Proxmox API endpoint"
  default     = "https://192.168.1.235:8006"
}

variable "proxmox_password" {
  description = "Proxmox root password — set via TF_VAR_proxmox_password env var"
  sensitive   = true
}

variable "worker_count" {
  description = "Number of Kubernetes worker nodes"
  default     = 2
}

variable "ssh_public_key" {
  description = "SSH public key for ubuntu user — set via TF_VAR_ssh_public_key env var"
  sensitive   = true
}

variable "node_name" {
  description = "Proxmox node name"
  default     = "rabtech"
}

variable "template_vm_id" {
  description = "VM ID of the Ubuntu cloud-init template"
  default     = 999
}

variable "datastore" {
  description = "Proxmox storage pool for VM disks"
  default     = "vmdata"
}

# ── Local values ─────────────────────────────────────────────────────────────
locals {
  common_tags = ["cairn", "kubernetes"]
  dns_servers = ["8.8.8.8", "8.8.4.4"]
}

# ── Control plane VM ─────────────────────────────────────────────────────────
resource "proxmox_virtual_environment_vm" "cp1" {
  name        = "cp-1"
  description = "Cairn Kubernetes control plane"
  node_name   = var.node_name
  vm_id       = 101
  tags        = concat(local.common_tags, ["control-plane"])

  # Boot from disk, not network
  boot_order = ["scsi0"]
  on_boot    = true

  clone {
    vm_id   = var.template_vm_id
    full    = true
    retries = 3
  }

  cpu {
    cores = 2
    type  = "host"
  }

  memory {
    dedicated = 4096
  }

  disk {
    datastore_id = var.datastore
    size         = 40
    interface    = "scsi0"
    discard      = "on"
    file_format  = "raw"
  }

  network_device {
    bridge   = "vmbr0"
    model    = "virtio"
    firewall = false
  }

  # QEMU guest agent — required for Proxmox to read IP
  agent {
    enabled = true
    timeout = "15m"
    trim    = true
  }

  initialization {
    ip_config {
      ipv4 {
        address = "dhcp"
      }
    }
    dns {
      servers = local.dns_servers
    }
    user_account {
      username = "ubuntu"
      keys     = [var.ssh_public_key]
      password = var.vm_password
    }
  }

  # Wait for VM to be ready before proceeding
  timeout_create   = 1800
  timeout_clone    = 1800
  timeout_start_vm = 600
}

# ── Worker VMs ────────────────────────────────────────────────────────────────
resource "proxmox_virtual_environment_vm" "workers" {
  count       = var.worker_count
  name        = "worker-${count.index + 1}"
  description = "Cairn Kubernetes worker node ${count.index + 1}"
  node_name   = var.node_name
  vm_id       = 102 + count.index
  tags        = concat(local.common_tags, ["worker"])

  boot_order = ["scsi0"]
  on_boot    = true

  clone {
    vm_id   = var.template_vm_id
    full    = true
    retries = 3
  }

  cpu {
    cores = 2
    type  = "host"
  }

  memory {
    dedicated = 6144
  }

  disk {
    datastore_id = var.datastore
    size         = 80
    interface    = "scsi0"
    discard      = "on"
    file_format  = "raw"
  }

  network_device {
    bridge   = "vmbr0"
    model    = "virtio"
    firewall = false
  }

  agent {
    enabled = true
    timeout = "15m"
    trim    = true
  }

  initialization {
    ip_config {
      ipv4 {
        address = "dhcp"
      }
    }
    dns {
      servers = local.dns_servers
    }
    user_account {
      username = "ubuntu"
      keys     = [var.ssh_public_key]
      password = var.vm_password
    }
  }

  timeout_create   = 1800
  timeout_clone    = 1800
  timeout_start_vm = 600
}

# ── Add this variable for VM console password ─────────────────────────────────
variable "vm_password" {
  description = "Password for ubuntu user — fallback if SSH key fails"
  sensitive   = true
  default     = "Cairn2026!"
}

# ── Outputs ───────────────────────────────────────────────────────────────────
output "cp1_vm_id" {
  description = "Control plane VM ID"
  value       = proxmox_virtual_environment_vm.cp1.vm_id
}

output "worker_vm_ids" {
  description = "Worker VM IDs"
  value       = proxmox_virtual_environment_vm.workers[*].vm_id
}

