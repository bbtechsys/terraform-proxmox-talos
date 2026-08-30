# 1.1 Upgrade Guide

What changes when moving from 1.0.x to 1.1.0 of `bbtechsys/talos/proxmox`.

**Nothing here requires action.** Unlike [1.0](UPGRADE-1.0.md), there are no state moves and
no forced replacements: every new capability is opt-in and every new variable defaults to the
existing behavior. A `terraform plan` against an unchanged configuration should report no
changes. Read the two behavior notes below before applying anyway.

## Behavior changes

### Node IPs are discovered by interface, not by position

1.0 read each node's address from `ipv4_addresses[7][0]`. Index 7 was not a contract — it
worked because the QEMU guest agent lists the seven interfaces Talos creates (`lo`, `bond0`,
`dummy0`, `teql0`, `tunl0`, `sit0`, `ip6tnl0`) before the real NIC. Adding a NIC, a VLAN or a
bond shifts it, and Talos changing how many dummy interfaces it makes would shift it too.

1.1 walks the reported interfaces and takes the first one with a routable IPv4, skipping
loopback, link-local and CNI interfaces (`flannel*`, `cni*`, `cali*`, `veth*`, `docker*`,
`kube-*`). It takes that interface's *first* address, so a Talos VIP — a second address on the
same NIC — is not mistaken for the node's own.

For a single-NIC node this resolves to exactly the same address; verified against a running
five-node cluster with flannel up, where `terraform plan` reported `No changes`.

**Check before applying if your nodes have more than one NIC.** If the old index happened to
land on a different interface than the new selection does, the resolved address changes, and
that address flows into the machine configuration and the `talos_config` output. Run
`terraform plan` and confirm you see no changes to `talos_machine_configuration_apply`.

### `= null` on the shared patch variables now means "use the default"

`control_machine_config_patches` and `worker_machine_config_patches` are now
`nullable = false`, because they are consumed through `concat()` and `concat` errors on a null
argument.

The side effect is that an explicit `null` no longer means "no patches at all" — Terraform
substitutes the default, which is the `machine.install.disk = /dev/vda` patch:

```terraform
control_machine_config_patches = null   # 1.0: no patches. 1.1: the default install-disk patch.
```

To send no patches, pass an empty list:

```terraform
control_machine_config_patches = []
```

If you never set these to `null`, nothing changes.

## New in 1.1

All optional, all defaulting to previous behavior.

| Variable | Default | Purpose |
| --- | --- | --- |
| `talos_cluster_endpoint` | `null` | Point the Kubernetes API endpoint at a VIP or load balancer instead of the first control node, removing the single point of failure. |
| `control_machine_config_patches_by_node`<br>`worker_machine_config_patches_by_node` | `{}` | Per-node config patches, appended after the shared lists so a node can override them. |
| `control_node_addresses`<br>`worker_node_addresses` | `{}` | Declare a node's address instead of discovering it. Skips the guest agent, disables `wait_for_ip` for that VM, and makes node IPs known at plan time. |
| `talos_platform` | `"metal"` | `"nocloud"` boots the Image Factory's nocloud image and configures networking from a Proxmox-generated cloud-init drive. |
| `node_network` | `null` | Prefix length, gateway and nameservers written to the cloud-init drive. |

See the README for [declaring node addresses](README.md#declaring-node-addresses),
[static addressing with no DHCP](README.md#static-addresses-with-no-dhcp-at-all) and the
[HA endpoint](README.md#high-availability-control-plane-endpoint-vip).

## ⚠️ Switching `talos_platform` replaces every VM

`talos_platform` is a create-time choice. Changing it on an existing cluster changes the image
file name, which changes each VM's `disk.file_id`, which is `ForceNew` — so every control-plane
and worker VM is destroyed and recreated, taking etcd and all workloads with it.

Set it when you build a cluster. To move an existing cluster onto `nocloud`, build a new one
alongside and migrate workloads.
