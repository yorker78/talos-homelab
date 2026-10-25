terraform {
  required_version = ">= 1.17"
  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "~> 0.118"
    }
    talos = {
      source  = "siderolabs/talos"
      version = "~> 0.12"
    }
  }
  # State lives on the runner (path set at init), never in git.
  backend "local" {}
}

locals {
  talos_version      = "v1.14.4"
  kubernetes_version = "v1.37.1"
  cluster_name       = "talos-homelab"
  proxmox_node       = "atlas"
  vm_datastore       = "local-lvm"
  gateway            = "192.168.1.1"

  nodes = {
    talos-1 = { vm_id = 200, ip = "192.168.1.20", type = "controlplane" }
    talos-2 = { vm_id = 201, ip = "192.168.1.21", type = "worker" }
    talos-3 = { vm_id = 202, ip = "192.168.1.22", type = "worker" }
  }
  control_plane_ip = local.nodes["talos-1"].ip
}

provider "proxmox" {
  endpoint = "https://atlas.home.arpa:8006/"
  # ponytail: Proxmox's self-signed cert; trust its CA instead if this repo ever leaves the LAN.
  insecure = true
  # API token comes from PROXMOX_VE_API_TOKEN.
}

provider "talos" {}

# Vanilla Talos image; add system extensions here when needed.
resource "talos_image_factory_schematic" "this" {
  schematic = yamlencode({ customization = {} })
}

data "talos_image_factory_urls" "this" {
  talos_version     = local.talos_version
  schematic_id      = talos_image_factory_schematic.this.id
  platform          = "nocloud"
  disk_image_format = "qcow2"
}

resource "proxmox_download_file" "talos" {
  node_name    = local.proxmox_node
  datastore_id = "local"
  content_type = "import"
  file_name    = "talos-${local.talos_version}-nocloud-amd64.qcow2"
  url          = data.talos_image_factory_urls.this.urls.disk_image
}

resource "proxmox_virtual_environment_vm" "node" {
  for_each = local.nodes

  name      = each.key
  vm_id     = each.value.vm_id
  node_name = local.proxmox_node
  tags      = ["talos", each.value.type]

  on_boot         = true
  stop_on_destroy = true

  cpu {
    cores = 2
    type  = "host"
  }

  memory {
    dedicated = 4096
  }

  disk {
    interface    = "scsi0"
    datastore_id = local.vm_datastore
    import_from  = proxmox_download_file.talos.id
    size         = 20
    discard      = "on"
  }

  network_device {
    bridge = "vmbr0"
  }

  operating_system {
    type = "l26"
  }

  # Talos's nocloud platform reads the static IP from this cloud-init drive.
  initialization {
    datastore_id = local.vm_datastore
    dns {
      domain  = "home.arpa"
      servers = [local.gateway]
    }
    ip_config {
      ipv4 {
        address = "${each.value.ip}/24"
        gateway = local.gateway
      }
    }
  }
}

resource "talos_machine_secrets" "this" {
  talos_version = local.talos_version
}

data "talos_machine_configuration" "node" {
  for_each = local.nodes

  cluster_name       = local.cluster_name
  cluster_endpoint   = "https://${local.control_plane_ip}:6443"
  machine_type       = each.value.type
  machine_secrets    = talos_machine_secrets.this.machine_secrets
  talos_version      = local.talos_version
  kubernetes_version = local.kubernetes_version
  # No install patch: the VMs boot from the Talos disk image, so Talos is already installed.
}

resource "talos_machine" "node" {
  for_each   = local.nodes
  depends_on = [proxmox_virtual_environment_vm.node]

  node                  = each.value.ip
  client_configuration  = talos_machine_secrets.this.client_configuration
  machine_configuration = data.talos_machine_configuration.node[each.key].machine_configuration
  # Matches the running version, so nothing upgrades; bump talos_version to upgrade the nodes.
  image = data.talos_image_factory_urls.this.urls.installer
  # Lets the provider drain a node before an upgrade reboot.
  kubeconfig_wo = ephemeral.talos_cluster_kubeconfig.this.kubeconfig_raw
}

# Generated from the secrets on each run and never stored in state.
ephemeral "talos_cluster_kubeconfig" "this" {
  cluster_name    = local.cluster_name
  machine_secrets = talos_machine_secrets.this.machine_secrets
  endpoint        = "https://${local.control_plane_ip}:6443"
}

resource "talos_cluster" "this" {
  depends_on = [talos_machine.node]

  node                 = local.control_plane_ip
  client_configuration = talos_machine_secrets.this.client_configuration
  kubernetes_version   = local.kubernetes_version
}

resource "talos_cluster_kubeconfig" "this" {
  depends_on = [talos_cluster.this]

  node                 = local.control_plane_ip
  client_configuration = talos_machine_secrets.this.client_configuration
}

data "talos_client_configuration" "this" {
  cluster_name         = local.cluster_name
  client_configuration = talos_machine_secrets.this.client_configuration
  endpoints            = [local.control_plane_ip]
  nodes                = [for n in local.nodes : n.ip]
}

output "talosconfig" {
  value     = data.talos_client_configuration.this.talos_config
  sensitive = true
}

output "kubeconfig" {
  value     = talos_cluster_kubeconfig.this.kubeconfig_raw
  sensitive = true
}
