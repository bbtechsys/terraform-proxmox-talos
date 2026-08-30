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

Check out our [blog post](https://bbtechsystems.com/blog/k8s-with-pxe-tf/) for more details on using this module.

Copyright (c) 2024 BB Tech Systems LLC
