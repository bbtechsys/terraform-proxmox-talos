# terraform-proxmox-talos

Terraform module to provision Talos Linux Kubernetes clusters with Proxmox

## Example usage

```bash
export PROXMOX_VE_USERNAME="root@pam"
export PROXMOX_VE_PASSWORD="super-secret"
```

```terraform
terraform {
  required_version = ">= 1.3"

  required_providers {
    proxmox = {
      source = "bpg/proxmox"
      version = "~> 0.111.1"
    }
    talos = {
      source = "siderolabs/talos"
      version = "~> 0.11.0"
    }
  }
}

provider "proxmox" {
  endpoint = "https://192.168.1.21:8006/"
  insecure = true
}

module "talos" {
    source  = "bbtechsys/talos/proxmox"
    version = "1.0.0"
    talos_cluster_name = "test-cluster"
    talos_version = "1.13.9"
    control_nodes = {
        "test-control-0" = "pve1"
        "test-control-1" = "pve1"
        "test-control-2" = "pve1"
    }
    worker_nodes = {
        "test-worker-0" = "pve1"
        "test-worker-1" = "pve1"
        "test-worker-2" = "pve1"
    }
}

output "talos_config" {
    description = "Talos configuration file"
    value       = module.talos.talos_config
    sensitive   = true
}

output "kubeconfig" {
    description = "Kubeconfig file"
    value       = module.talos.kubeconfig
    sensitive   = true
}
```

## Upgrading from 0.1.x

**Upgrading to 1.0.0 will destroy and recreate every VM unless you add a `moved` block
first.** Read the
[1.0 Upgrade Guide](https://github.com/bbtechsys/terraform-proxmox-talos/blob/main/UPGRADE-1.0.md)
before you run `terraform apply`.

## The Talos boot image

The module downloads the Talos image named by `talos_schematic_id`, `talos_version` and
`talos_arch` from [factory.talos.dev](https://factory.talos.dev/) into `proxmox_iso_datastore`.
The schematic **must** include the `qemu-guest-agent` extension — the default one does —
because node IPs are read back from the guest agent.

How many copies are downloaded depends on the datastore, and is worked out automatically
from the datastore's `shared` flag in Proxmox:

- **Shared datastore** (NFS, CIFS, CephFS, a ZFS pool flagged shared): one download for the
  whole cluster, since every host sees the same file.
- **Node-local datastore** (the `local` default): one download per distinct Proxmox host
  named in `control_nodes` or `worker_nodes`. The datastore must exist, and accept `iso`
  content, on every one of those hosts.

Set `proxmox_iso_datastore_shared` only if a datastore's `shared` flag in Proxmox does not
match reality — for example a `dir` store that is backed by a filesystem shared outside of
Proxmox's knowledge. Use `talos_image_upload_timeout` to raise the per-download 600s timeout
on a slow link.

## High-availability control plane endpoint (VIP)

By default the cluster endpoint points at the first control node's IP, which is a
single point of failure. To make it highly available, set `talos_cluster_endpoint` to a
shared [Talos VIP](https://www.talos.dev/latest/talos-guides/network/vip/) and
define that VIP on the control nodes via a config patch:

```terraform
module "talos" {
  source  = "bbtechsys/talos/proxmox"
  # ... cluster_name, version, nodes ...

  talos_cluster_endpoint = "https://192.168.88.200:6443" # shared VIP

  control_machine_config_patches = [
    yamlencode({
      machine = {
        install = { disk = "/dev/vda" }
        network = {
          interfaces = [{
            interface = "eth0"
            dhcp      = true
            vip       = { ip = "192.168.88.200" }
          }]
        }
      }
    })
  ]
}
```

`talos_cluster_endpoint` defaults to `null` (legacy first-node behavior), so this change
is fully backward compatible.

## Per-node configuration patches

`control_machine_config_patches_by_node` and `worker_machine_config_patches_by_node` are maps keyed by
node name. Their patches are appended *after* the shared
`control_machine_config_patches` / `worker_machine_config_patches`, so they can
override shared values — useful for per-node tuning such as kubelet args or node
labels:

```terraform
  worker_machine_config_patches_by_node = {
    "test-worker-0" = [yamlencode({
      machine = { kubelet = { extraArgs = { "node-labels" = "gpu=true" } } }
    })]
  }
```

Both default to `{}`, so they are backward compatible.

> Note: avoid using these to set static node IPs via `dhcp: false`. This module
> discovers node IPs through the guest agent and assumes they are stable, so a
> static-address patch can change a node's IP out from under that discovery (or
> strand the node). For predictable IPs, pin a `mac_address` and use a DHCP
> reservation instead.

Check out our [blog post](https://bbtechsystems.com/blog/k8s-with-pxe-tf/) for more details on using this module.

Copyright (c) 2024 BB Tech Systems LLC
