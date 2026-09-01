# 1.3 Upgrade Guide

What changes when moving from 1.2.x to 1.3.0 of `bbtechsys/talos/proxmox`.

No state moves, no forced replacements, and the new behavior is opt-in. Bumping the version alone
produces an empty plan.

## Nodes can have a second interface

Every node had exactly one network device. That is fine until the cluster needs to reach a network
it should be *on* rather than route to — a Ceph public network on its own VLAN and its own NICs
being the usual case.

`node_additional_network` adds a second interface to every node, with per-node addresses:

```terraform
  node_additional_network = {
    bridge        = "vmbr1"
    vlan_id       = 12
    mtu           = 9000
    prefix_length = 24
  }

  worker_node_additional_addresses = { "kirkwood-worker-0" = "10.32.12.84" }
```

It becomes `net1`, so the primary interface stays `net0` and any config patch selecting on
`link.driver == "virtio_net"` — including the `LinkAliasConfig` in the VIP example — now matches
**two** links rather than one. If you use a VIP, narrow that selector before upgrading:

```terraform
  selector = { match = "link.bus_path == \"0000:00:12.0\"" }
```

Proxmox puts `net0` at PCI slot `0x12` and `net1` at `0x13`. Two things about that field name,
both of which cost an apply cycle to find:

- It is `bus_path`, not `busPath`. Selectors are evaluated against the protobuf descriptor, so
  field names are snake_case even though `talosctl get links -o yaml` prints them camelCase.
- There is no `link.name`. The interface name is the resource ID, not part of the spec, so it
  cannot be selected on at all.

All three variables default to unset, so existing configurations are unaffected.

### Why you would want it

Routing to a storage network works until it doesn't. When the storage hosts are dual-homed, the
return path bypasses the router, a stateful firewall sees only one direction, and its state entry
is reaped. Short operations still succeed, so the failure is confusing: volumes provision and PVCs
bind, then pods hang in `ContainerCreating` while `NodeStageVolume` logs a slow GRPC request every
30 seconds and the kernel logs `rbd: encountered watch error: -107`.

Being directly attached removes the router from the path entirely.

### Two things to get right

- **MTU must match the segment.** On-link traffic gets no path MTU discovery. If the other hosts
  send 9000-byte frames and this interface is 1500, those frames are dropped on arrival.
- **`talos_platform` must be `nocloud`.** The address reaches the node through the cloud-init
  drive, so there is no way to deliver it on the `metal` image.

## New variables

| Variable | Default | Purpose |
| --- | --- | --- |
| `node_additional_network` | `null` | Bridge, VLAN, MTU and prefix length for a second interface on every node. |
| `control_node_additional_addresses` | `{}` | Per-control-node address on that network. |
| `worker_node_additional_addresses` | `{}` | Per-worker address on that network. |
