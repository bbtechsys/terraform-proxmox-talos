# 1.3 Upgrade Guide

What changes when moving from 1.2.x to 1.3.0 of `bbtechsys/talos/proxmox`.

There are no state moves, no forced replacements, no new plan-time validation, and no behavior
change unless you opt in. Bumping the version alone produces an empty plan.

## Workers can now be sized individually

`proxmox_worker_vm_cores`, `proxmox_worker_vm_memory` and `proxmox_worker_vm_disk_size` size
every worker identically. That is the right default, and it is wrong whenever the Proxmox hosts
are not identical: the largest host either goes underused, or you put extra workers on it and
concentrate the failure domain there.

1.3 adds three maps keyed by worker node name, each overriding the corresponding flat variable
for the nodes it names:

```terraform
  proxmox_worker_vm_cores  = 4      # applies to workers not named below
  proxmox_worker_vm_memory = 8192

  worker_vm_cores_by_node  = { "kirkwood-worker-0" = 8 }
  worker_vm_memory_by_node = { "kirkwood-worker-0" = 16384 }
```

All three default to `{}`. A worker with no entry keeps the flat value, which is what every
existing configuration has — hence the empty plan on upgrade.

Keys are read with `lookup`, so unlike the `_by_node` patch maps added in 1.2 a key matching no
worker is silently ignored rather than rejected at plan. That asymmetry is deliberate: a dropped
config patch changes cluster behavior invisibly, whereas a dropped sizing override is visible in
the plan as a VM that did not change size.

### Two things to know before using it

- **Proxmox cannot shrink a disk.** Lowering `worker_vm_disk_size_by_node` for a node that
  already exists fails the apply with a provider error. Raising it is fine.
- **Changing cores or memory restarts the VM.** Terraform updates workers in parallel unless you
  constrain it, so drain deliberately or apply with `-parallelism=1` if the workloads care.

### Why workers only

There is no control-plane equivalent, and adding one would be a mistake. Control nodes hold an
etcd quorum; members with materially different CPU and memory produce election and compaction
behavior that is difficult to reason about when something goes wrong. Size control nodes
identically and put the asymmetry in the workers.

## New variables

| Variable | Default | Purpose |
| --- | --- | --- |
| `worker_vm_cores_by_node` | `{}` | Per-worker CPU core count, overriding `proxmox_worker_vm_cores`. |
| `worker_vm_memory_by_node` | `{}` | Per-worker memory in MB, overriding `proxmox_worker_vm_memory`. Sets dedicated and floating together, as the flat variable does. |
| `worker_vm_disk_size_by_node` | `{}` | Per-worker boot disk size in GB, overriding `proxmox_worker_vm_disk_size`. Cannot be lowered for an existing node. |
