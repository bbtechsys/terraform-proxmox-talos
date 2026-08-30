# 1.0 Upgrade Guide

What breaks when moving from 0.1.x to 1.0.0 of `bbtechsys/talos/proxmox`, and how to get
through it.

## The Talos image is now downloaded per Proxmox host

**The bug this fixes:** the image was only ever downloaded onto the Proxmox host of the
first control node. If `control_nodes` or `worker_nodes` placed a VM on any other host, and
`proxmox_iso_datastore` was not shared across the cluster, that host had no boot image and
the VM could not be created. The image is now downloaded onto every host that needs one.

How many copies you get is worked out from the datastore's `shared` flag in Proxmox, so no
configuration change is required:

- **Shared** (NFS, CIFS, CephFS, a ZFS pool flagged shared) — one download for the whole
  cluster, as before.
- **Node-local** (the `local` default) — one download per distinct Proxmox host named in
  `control_nodes` or `worker_nodes`. The datastore must exist, and accept `iso` content, on
  every one of those hosts, or the plan fails with an error naming the host.

## ⚠️ This upgrade destroys and recreates every VM unless you act

Two things changed about the image resource at once. It was renamed to the provider's short
form, and it is now keyed by Proxmox host:

| Before | After |
| --- | --- |
| `proxmox_virtual_environment_download_file.talos_image` | `proxmox_download_file.talos_image["<host>"]` |

Terraform sees no relationship between those two addresses. Left alone, it plans to destroy
the old resource and create a new one, and the new one's `id` is not known until apply. Every
VM's boot disk `file_id` is derived from that `id`, and `file_id` forces replacement — so
**every control-plane and worker VM is destroyed and recreated**, taking etcd, all workloads,
and anything stored on VM-local disks with it.

Always read the plan before applying. If you see your VMs under `must be replaced`, stop and
pick one of the options below.

### Option 1 — don't upgrade yet

Pin the module and carry on. Nothing in 1.0.0 is a security fix.

```terraform
module "talos" {
  source  = "bbtechsys/talos/proxmox"
  version = "~> 0.1.5"
  # ...
}
```

### Option 2 — upgrade in place, keeping your cluster (Terraform >= 1.8)

Tell Terraform the resource moved. Add this to your **root** module, alongside the `module`
block, and find `<host>` by reading `node_name` out of your current state:

```shell
terraform state show 'module.talos.proxmox_virtual_environment_download_file.talos_image'
```

```terraform
moved {
  from = module.talos.proxmox_virtual_environment_download_file.talos_image
  to   = module.talos.proxmox_download_file.talos_image["pve1"] # <- your node_name
}
```

Run `terraform plan` and confirm it reports `0 to add, 0 to change, 0 to destroy` (a
node-local datastore spanning several hosts will additionally show one new download per extra
host, which does not touch your VMs). Apply, then delete the `moved` block.

Terraform 1.8 is the minimum, because moving between two different resource types is only
supported from that version. `terraform state mv` is **not** an alternative here — it refuses
to move between resource types with `resource types don't match`.

### Option 3 — let it recreate

Fine for a cluster you can rebuild. Everything on it is lost.

## Minimum versions raised

| | Before | After |
| --- | --- | --- |
| Terraform | (unset) | `>= 1.3` |
| `bpg/proxmox` | `>= 0.68.0` | `>= 0.111.1` |
| `siderolabs/talos` | `>= 0.6.1` | `>= 0.11.0` |

The provider floor is load-bearing: the `datastores` data source this module now reads was
restructured in `bpg/proxmox` 0.75.0. Review the
[provider's own upgrade guide](https://registry.terraform.io/providers/bpg/proxmox/latest/docs/guides/upgrade)
if you are crossing several of its releases at once.

## New variables

| Variable | Default | Purpose |
| --- | --- | --- |
| `proxmox_iso_datastore_shared` | `null` (detect) | Override the datastore's `shared` flag when Proxmox reports it wrongly — for example a `dir` store on a filesystem shared outside Proxmox's knowledge. |
| `talos_image_upload_timeout` | `600` | Seconds allowed for each image download. Raise it on a slow link, especially with several hosts downloading at once. |
