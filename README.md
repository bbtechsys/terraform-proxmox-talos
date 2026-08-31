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
    version = "1.2.0"
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

## Upgrading

- **1.1.x → 1.2.0** — no state moves or replacements, but apply now waits for the cluster to be
  healthy, and two previously silent misconfigurations now fail at plan. See the
  [1.2 Upgrade Guide](https://github.com/bbtechsys/terraform-proxmox-talos/blob/main/UPGRADE-1.2.md).
- **1.0.x → 1.1.0** — additive; no state moves and no forced replacements. Two behavior notes
  worth reading first, in the
  [1.1 Upgrade Guide](https://github.com/bbtechsys/terraform-proxmox-talos/blob/main/UPGRADE-1.1.md).
- **0.1.x → 1.0.0** — **destroys and recreates every VM** unless you add a `moved` block first.
  Read the
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

## Waiting for the cluster to be ready

Talos hands over the kubeconfig as soon as bootstrap finishes, which is before
kube-apiserver is serving — and with a VIP, before the endpoint address exists at all. So
`terraform apply && kubectl apply -f ...` races the cluster coming up. Setting
`wait_for_cluster_health = true` blocks apply until the cluster reports healthy, which closes
that race:

```terraform
  wait_for_cluster_health = true
```

**It is off by default deliberately.** The check is a data source, so Terraform re-reads it on
every refresh and plan, not only when creating the cluster. A cluster that is temporarily
degraded — a node powered off for maintenance, a control node mid-reboot — will then fail
`terraform plan` until it recovers, which is exactly when you need to plan a fix. Turn it on
for first provisioning and for CI, where the guarantee is worth more than planning against a
sick cluster.

Two knobs come with it:

- `cluster_health_skip_kubernetes_checks` — **required if you disable the built-in CNI**
  (`cluster.network.cni.name = "none"`, the usual way to install Cilium). Nodes stay `NotReady`
  until that CNI is deployed, which happens after Terraform finishes, so the Kubernetes checks
  would never pass. This keeps the etcd and boot checks and drops only the Kubernetes ones.
- `cluster_health_timeout` — a duration such as `"20m"`. A five-node cluster took about four
  and a half minutes to report healthy, so larger clusters or slow storage may need more than
  the provider default.

One limitation worth knowing: the check talks to the control nodes' own addresses, never to
`talos_cluster_endpoint`, because Talos documents that a VIP must not be used as a Talos API
endpoint. If you use a VIP, a healthy result means etcd and kube-apiserver are up on the nodes
— the VIP is claimed as a consequence of that same etcd election, but nothing here explicitly
waits for the claim.

## Declaring node addresses

By default this module learns each node's IP from the QEMU guest agent. If you already know
what a node's address will be, declare it instead with `control_node_addresses` /
`worker_node_addresses`, keyed by node name:

```terraform
  control_node_addresses = {
    "talos-control-0" = "10.0.0.11"
  }
```

For any node listed there the module uses that address instead of the guest agent, and does
not wait for the agent to report an IP. Node addresses become known at plan time rather than
after apply, and a Talos VIP can no longer be mistaken for a node's own address. Nodes you
leave out keep using discovery, so mixing the two is fine.

> **The node must already answer on that address when Terraform first contacts it.**
> Declaring an address does not assign one. In practice that means a DHCP reservation
> against the node's MAC — see `control_plane_mac_addresses` / `worker_mac_addresses`.

### Making the address permanent in Talos

To pin the address inside Talos as well, patch a `LinkConfig` (Talos 1.13+; see the note
below about interface names):

```terraform
  control_machine_config_patches_by_node = {
    "talos-control-0" = [
      yamlencode({
        apiVersion = "v1alpha1"
        kind       = "LinkConfig"
        name       = "ens18"
        addresses  = [{ address = "10.0.0.11/24" }]
        routes     = [{ gateway = "10.0.0.1" }]
      }),
      yamlencode({
        apiVersion  = "v1alpha1"
        kind        = "ResolverConfig"
        nameservers = [{ address = "10.0.0.1" }]
      }),
    ]
  }
```

Keep this in sync with `control_node_addresses`. If they disagree, the apply hangs trying to
reach an address nothing answers on.

### Static addresses with no DHCP at all

The section above still relies on something handing the node an address before Terraform can
reach it. To remove DHCP entirely, boot the Image Factory's **nocloud** image instead: Proxmox
generates a cloud-init drive from the VM's settings, and Talos reads its networking from that
drive at boot, before any API call.

```terraform
  talos_platform = "nocloud"

  node_network = {
    prefix_length = 24
    gateway       = "10.32.1.1"
    nameservers   = ["10.32.1.1"]
  }

  control_node_addresses = { "nc-control-0" = "10.32.1.80" }
  worker_node_addresses  = { "nc-worker-0"  = "10.32.1.83" }
```

That is the whole configuration — Proxmox builds the cloud-init drive through its API, so this
needs **no snippets datastore and no SSH access** to the hosts. Every node listed gets its
address at boot, and `agent.wait_for_ip` is disabled for it, so nothing waits on the guest
agent. Nodes without a declared address are unaffected and keep using DHCP.

Verified on a live cluster: Talos reports the address as coming from the platform rather than
DHCP, and no DHCP lease exists on the node —

```console
$ talosctl get addressspecs --namespace network-config
NODE         NAMESPACE        TYPE          ID
10.32.1.80   network-config   AddressSpec   platform/eth0/10.32.1.80/24
```

Three things to know:

- **Switching `talos_platform` replaces every VM.** It changes the image file name, hence each
  VM's `disk.file_id`, which is ForceNew. Choose it when creating a cluster; changing it later
  rebuilds one.
- **The nocloud image names the NIC `eth0`**, unlike the metal image, which uses predictable
  names such as `ens18`. This matters for any config patch that refers to an interface — see
  the VIP section below.
- **Nodes get their Terraform name as hostname.** On the metal image Talos generates a random
  one like `talos-0uk-jxa`; with cloud-init the Kubernetes node is named `nc-control-0`.

## High-availability control plane endpoint (VIP)

By default the cluster endpoint points at the first control node's IP, which is a
single point of failure. To make it highly available, set `talos_cluster_endpoint` to a
shared [Talos VIP](https://docs.siderolabs.com/talos/v1.13/networking/advanced/vip) and
define that VIP on the control nodes via config patches.

The VIP config format is **Talos-version specific**. The example below is for Talos
**1.13 and later**, which configures networking through standalone config documents.
On Talos 1.12 and earlier the equivalent lives under `machine.network.interfaces[].vip`
— check the VIP guide for the version you pin in `talos_version`.

```terraform
module "talos" {
  source  = "bbtechsys/talos/proxmox"
  version = "1.2.0"                    # talos_cluster_endpoint is not in 1.0.0
  # ... talos_cluster_name, nodes ...

  talos_version          = "1.13.9"
  talos_cluster_endpoint = "https://192.168.88.200:6443" # the shared VIP

  # Recommended: pair a VIP with nocloud + declared addresses (see above). It removes
  # the guest-agent interaction described below, and node IPs become known at plan time.
  talos_platform = "nocloud"

  control_machine_config_patches = [
    # Supplying this list REPLACES the module default, so re-include the install disk.
    yamlencode({ machine = { install = { disk = "/dev/vda" } } }),

    # Give the NIC a stable alias, selected by driver rather than by name. The metal
    # image uses predictable names (ens18) and the nocloud image uses eth0, so there is
    # no single interface name that works on both — but the driver is virtio_net on
    # either, and it matches exactly one link, which Layer2VIPConfig requires.
    yamlencode({
      apiVersion = "v1alpha1"
      kind       = "LinkAliasConfig"
      name       = "net0"
      selector   = { match = "link.driver == \"virtio_net\"" }
    }),

    # Advertise the VIP on that alias, elected between control nodes via etcd.
    yamlencode({
      apiVersion = "v1alpha1"
      kind       = "Layer2VIPConfig"
      name       = "192.168.88.200"
      link       = "net0"
    }),
  ]
}
```

`talos_cluster_endpoint` defaults to `null` (legacy first-node behavior), so this change
is fully backward compatible.

Verified on a live 3-control-node cluster: Talos logs `enabled shared IP {"operator": "vip",
"link": "ens18", "ip": ...}` once etcd elects a leader, and `kubectl` works through the VIP
endpoint. Note the alias resolves to the real link, so `link: net0` is what you write and
`ens18` (or `eth0`) is what Talos binds.

### Before you use a VIP

A Talos VIP is not a load balancer. It is a shared address claimed by one control node at
a time through an etcd election, which carries real constraints — all quoted from the
[Talos VIP guide](https://docs.siderolabs.com/talos/v1.13/networking/advanced/vip):

- **Control nodes must share a layer 2 network**, "connected via a switch, with no router
  in between them", and the VIP must come from that subnet and be an address your DHCP
  server will never hand out. A routed multi-subnet Proxmox cluster cannot use this
  pattern — put a real load balancer in front and point `talos_cluster_endpoint` at it.
- **The VIP does not come up until after Kubernetes is bootstrapped**, because the
  election depends on etcd. During the first `terraform apply` the endpoint written into
  every machine config is unreachable, so `apply` can return a `kubeconfig` whose server is not
  answering yet. `wait_for_cluster_health = true` (above) closes most of this gap, though it
  waits on the control nodes rather than on the VIP itself.
- **Unexpected failover takes up to a minute**, by design, to avoid split brain. Graceful
  shutdown reassigns almost instantly.
- **Do not use the VIP as the Talos API endpoint.** Talos is explicit: the VIP is bound to
  etcd and kube-apiserver health, so you could not reach the Talos API to recover etcd.

That last point interacts with this module. A VIP is a second address on the same NIC, so the
QEMU guest agent reports it — confirmed on a live cluster, where the node holding the VIP
reported `ens18: ['10.32.1.234', '10.32.1.88']`. Discovery takes the interface's *first*
address, so it picks the node's own, but that ordering is not something the guest agent
guarantees.

The clean answer is to not use discovery at all: set `talos_platform = "nocloud"` and declare
`control_node_addresses`. Node IPs then come from your configuration rather than from the
agent, so the VIP cannot be mistaken for one no matter what the agent reports. If you stay on
discovery, check the `control_plane_ips` output after applying and confirm the VIP is absent.

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

## Per-node VM sizing

`proxmox_worker_vm_cores`, `proxmox_worker_vm_memory` and `proxmox_worker_vm_disk_size` size
every worker the same. When the Proxmox hosts are not identical, override them for individual
workers with `worker_vm_cores_by_node`, `worker_vm_memory_by_node` and
`worker_vm_disk_size_by_node`:

```terraform
  worker_nodes = {
    "kirkwood-worker-0" = "pve1"   # the large host
    "kirkwood-worker-1" = "pve2"
    "kirkwood-worker-2" = "pve3"
  }

  proxmox_worker_vm_cores  = 4      # the default for workers not named below
  proxmox_worker_vm_memory = 8192

  worker_vm_cores_by_node  = { "kirkwood-worker-0" = 8 }
  worker_vm_memory_by_node = { "kirkwood-worker-0" = 16384 }
```

All three default to `{}`, so they are backward compatible.

The reason to reach for this rather than simply putting *more* workers on the larger host is
the failure domain. Two workers on `pve1` means losing `pve1` costs half your worker capacity;
one larger worker on `pve1` means losing any single host costs exactly one worker, whichever
host it is.

Two caveats:

- **Proxmox cannot shrink a disk.** Lowering `worker_vm_disk_size_by_node` for an existing node
  fails the apply. Raising it is fine.
- **Changing cores or memory restarts the VM**, one worker at a time. On a cluster with
  workloads that tolerate a node draining this is routine; it is still a restart.

There is deliberately no control-plane equivalent. Control nodes should be identical — an etcd
quorum whose members have different resources fails in ways that are tedious to reason about.

Check out our [blog post](https://bbtechsystems.com/blog/k8s-with-pxe-tf/) for more details on using this module.

Copyright (c) 2024 BB Tech Systems LLC
