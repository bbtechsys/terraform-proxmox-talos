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
  version = "~> 1.1"                   # talos_cluster_endpoint is not in 1.0.0
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
  every machine config is unreachable, and this module does not gate on cluster health, so
  `apply` can return a `kubeconfig` whose server is not answering yet.
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

Check out our [blog post](https://bbtechsystems.com/blog/k8s-with-pxe-tf/) for more details on using this module.

Copyright (c) 2024 BB Tech Systems LLC
