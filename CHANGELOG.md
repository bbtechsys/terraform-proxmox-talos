# Changelog

Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versioning follows
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Anything that needs saying about a release is said here, under **Watch out** where it can bite.
An upgrade involved enough to need step-by-step instructions gets its own guide, linked from its
entry; 1.0.0 is the only one so far.

## [Unreleased]

## [1.3.0]

### Added

- `node_additional_network`, with `control_node_additional_addresses` and
  `worker_node_additional_addresses` — a second interface on every node, for a network the nodes
  must be **on** rather than route to. Becomes `net1`, takes no gateway, and requires
  `talos_platform = "nocloud"`.

  Routing to a storage network fails badly when the storage hosts are dual-homed: replies bypass
  the router, a stateful firewall sees one direction only, and its state entry is reaped. Short
  operations still succeed, so volumes provision and PVCs bind, then pods hang in
  `ContainerCreating` with `rbd: encountered watch error: -107`.

### Watch out

- **A second interface breaks the VIP example.** `link.driver == "virtio_net"` now matches two
  links, and `Layer2VIPConfig` requires exactly one. Select on the PCI slot instead —
  `link.bus_path == "0000:00:12.0"` for `net0`. Note it is `bus_path`, not `busPath`: selectors
  evaluate against the protobuf descriptor. There is no `link.name`.
- **Match the segment's MTU.** These interfaces are on-link, so there is no path MTU discovery —
  9000-byte frames arriving at a 1500 interface are dropped.

## [1.2.1]

### Added

- `worker_vm_cores_by_node`, `worker_vm_memory_by_node`, `worker_vm_disk_size_by_node` — size
  individual workers differently, so uneven Proxmox hosts can carry uneven workers without
  stacking them onto one host. There is deliberately no control-plane equivalent: an etcd quorum
  with uneven members is hard to reason about.

### Watch out

- Proxmox cannot shrink a disk, so lowering `worker_vm_disk_size_by_node` for an existing node
  fails the apply.
- Released as a patch. New inputs would normally warrant a minor.

## [1.2.0]

### Added

- `wait_for_cluster_health`, `cluster_health_skip_kubernetes_checks`, `cluster_health_timeout` —
  block apply until the cluster serves.

### Changed

- Bootstrap now waits for the control plane to be configured, and workers are configured after
  bootstrap. Both previously worked by graph luck.

### Fixed

- `talos_cluster_endpoint` is validated at plan time; malformed values used to reach every node's
  machine configuration.
- `_by_node` patch keys matching no node fail at plan instead of being silently dropped.

### Watch out

- `wait_for_cluster_health` is a **data source**, so it is re-read on every plan *and on destroy*.
  Leave it off for day-to-day: a node down for maintenance will otherwise block both.
- Disabling the built-in CNI requires `cluster_health_skip_kubernetes_checks = true`, or nodes
  never go Ready and every apply fails.

## [1.1.0]

### Added

- `talos_cluster_endpoint` — a shared VIP or load balancer instead of the first control node.
- `talos_platform = "nocloud"` — static addressing with no DHCP at all.
- Per-node config patches.

### Watch out

- **Changing `talos_platform` replaces every VM.** It changes the image file name, hence each VM's
  `disk.file_id`, which is `ForceNew`. Choose it when creating a cluster.
- The VIP is not claimed until after Kubernetes bootstraps, because the election depends on etcd.
- Never use the VIP as the *Talos* API endpoint — it depends on etcd and kube-apiserver health, so
  you could not reach Talos to recover etcd.

## [1.0.0]

### Changed

- The Talos image is downloaded per Proxmox host, with shared datastores detected so it downloads
  once for the cluster.
- Minimum provider versions raised.

### Watch out

- **This upgrade destroys and recreates every VM unless you act**, because the image resource is
  now keyed per host. This one needs more than a changelog entry — see
  [UPGRADE-1.0.md](https://github.com/bbtechsys/terraform-proxmox-talos/blob/main/UPGRADE-1.0.md)
  for the `moved` block that avoids it.

## Earlier

0.1.x predates this changelog. See the
[releases page](https://github.com/bbtechsys/terraform-proxmox-talos/releases).

[Unreleased]: https://github.com/bbtechsys/terraform-proxmox-talos/compare/1.3.0...HEAD
[1.3.0]: https://github.com/bbtechsys/terraform-proxmox-talos/compare/1.2.1...1.3.0
[1.2.1]: https://github.com/bbtechsys/terraform-proxmox-talos/compare/1.2.0...1.2.1
[1.2.0]: https://github.com/bbtechsys/terraform-proxmox-talos/compare/1.1.0...1.2.0
[1.1.0]: https://github.com/bbtechsys/terraform-proxmox-talos/compare/1.0.0...1.1.0
[1.0.0]: https://github.com/bbtechsys/terraform-proxmox-talos/compare/0.1.6...1.0.0
