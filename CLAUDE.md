# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A **published Terraform module** (`bbtechsys/talos/proxmox` on the Terraform Registry) that provisions a Talos Linux Kubernetes cluster on Proxmox VE. The repository root *is* the module — there is no `modules/` directory, no example subdirectory, and no root-level provider config in git. Consumers supply their own `provider "proxmox"` block and credentials (`PROXMOX_VE_USERNAME` / `PROXMOX_VE_PASSWORD` env vars).

Because it ships as a module, treat `variables.tf` and `outputs.tf` as the public API: renaming or removing a variable/output is a breaking change for downstream users, and README example usage should stay in sync with them. The same applies to resource addresses: consumers hold them in state, so re-keying or renaming a resource forces replacement unless a `moved` block covers it.

## Commands

```bash
terraform init
terraform fmt        # note: existing files use 4-space indent, which `fmt` will rewrite to 2
terraform validate
terraform plan  -var-file=test.tfvars
terraform apply -var-file=test.tfvars
```

There is no test suite, linter config, or CI. Validation beyond `terraform validate` requires a live Proxmox host — `terraform plan` against real infrastructure is the only meaningful end-to-end check. `test.tfvars` and `provider.tf` are untracked local scratch files pointing at the maintainer's Proxmox host; they are not part of the module.

## Architecture

Everything lives in `main.tf` and runs in one dependency chain:

1. **`proxmox_download_file.talos_image`** pulls a qcow2 from `factory.talos.dev` built from `var.talos_schematic_id` + `var.talos_version` + `var.talos_arch`, `for_each` over `local.talos_image_hosts`. `data.proxmox_datastores.iso` decides how many copies that is: a downloaded file's Proxmox volume ID is `<datastore>:iso/<file_name>` with no node component, so a **shared** `proxmox_iso_datastore` is visible from every host and one download suffices, while a **node-local** one (the `local` default) needs a copy on each host running cluster nodes. `var.proxmox_iso_datastore_shared` overrides the detected flag; `local.talos_image_ids` maps each Proxmox host to the image it boots from. A `lifecycle.precondition` fails the plan with a host-specific message when the datastore is missing or does not accept `iso` content there.

2. **`proxmox_virtual_environment_vm.talos_control_vm` / `talos_worker_vm`** — `for_each` over `var.control_nodes` / `var.worker_nodes`, which are `map(talos_node_name => proxmox_host_name)`. The map keys are both the VM names and the resource addresses, so renaming a key destroys and recreates that node.
3. **Talos config** — `talos_machine_secrets` → `data.talos_machine_configuration` (one for controlplane, one for worker) → `talos_machine_configuration_apply` per node → `talos_machine_bootstrap` on the primary control node → `talos_cluster_kubeconfig`.

Ordering is mostly implicit via resource references, with four explicit `depends_on` edges that references alone do not create: kubeconfig on bootstrap; bootstrap on `talos_control_mc_apply` (it references only the node IP and the secrets, so nothing otherwise ordered it after the control plane was configured); `talos_worker_mc_apply` on bootstrap (a worker's config names the cluster endpoint, which with a VIP does not exist until bootstrap completes); and `data.talos_cluster_health` on `talos_worker_mc_apply` plus bootstrap (the control apply is reached transitively through bootstrap, so it is not listed). That health check is what the `kubeconfig` output depends on, so apply does not return until the cluster is serving — gated by `var.wait_for_cluster_health`, **default false**, because a data source is re-read on every plan and a degraded cluster would otherwise block planning. `talos_config` is deliberately *not* gated: it is local computation from the secrets and node IPs, and it is the talosctl config you need to debug an unhealthy cluster. Do not remove these edges; each one is a bug that was fixed.

### Two things that constrain most changes

**IP discovery defaults to the QEMU guest agent.** `local.control_node_ip` / `local.worker_node_ip` resolve each node to `var.<control|worker>_node_addresses[name]` when declared, otherwise to `local.*_node_discovered_ip`, which walks `network_interface_names` and takes the first interface reporting a routable IPv4 — skipping loopback, link-local, and CNI interfaces by name prefix. It deliberately does **not** index a fixed position: the agent lists Talos's dummy interfaces (bond0, dummy0, teql0, tunl0, sit0, ip6tnl0) before the real NIC, which is why `[7]` used to work, and that count is not a contract. It takes the interface's *first* address so a Talos VIP, a second address on the same NIC, is not picked up.

Declaring an address also sets `agent.wait_for_ip.disabled` for that VM. On the default `metal` platform it does not *assign* the address — the node must already answer there (a DHCP reservation), because machine config is delivered over the network. With `var.talos_platform = "nocloud"` the module attaches a Proxmox-generated cloud-init drive (`initialization.ip_config`, built from `var.node_network`), so Talos configures the address at boot and no DHCP is needed at all; this is verified working, with `talosctl get addressspecs --namespace network-config` reporting `platform/eth0/…` rather than `dhcp4/…`. Note the nocloud image names the NIC `eth0` where metal uses `ens18`, and that switching platform changes the image file name and therefore replaces every VM. Everything below applies to nodes left to discovery, which is still the default:
- The Talos schematic **must** include the `qemu-guest-agent` extension (the default `talos_schematic_id` does), or the apply hangs/fails with no IPs.
- Extra NICs or VLANs change what the agent reports; discovery picks the first routable non-CNI interface, so an added NIC that comes up first would win.
- A Talos VIP is a second address on the same NIC. Verified on a live cluster: the holder reports `['10.32.1.234', '10.32.1.88']`, node address first — which is why discovery takes `[0]` and not a scan.

**The cluster endpoint defaults to a single point of failure.** `local.resolved_cluster_endpoint` is `coalesce(var.talos_cluster_endpoint, "https://${local.primary_control_node_ip}:6443")`, where the primary is `keys(var.control_nodes)[0]`. Left unset, both machine configurations point at that one node, exactly as before the override existed. `var.talos_cluster_endpoint` takes a VIP or load-balancer address instead.

Note that a Talos VIP interacts badly with the IP discovery above: it is a second address on the same NIC, so the guest agent reports it and `ipv4_addresses[7][0]` can return the VIP on whichever node currently holds it — which would feed the VIP into `talos_machine_bootstrap` and the `talos_config` output, which Talos forbids. Nothing gates apply on cluster health either, so with a VIP the emitted kubeconfig may point at an address that is not answering yet. The README documents both caveats; see the open issues before extending this.

### Machine config patching

Users customize Talos via `var.control_machine_config_patches` / `var.worker_machine_config_patches` (lists of YAML strings). Both default to a patch setting `machine.install.disk = /dev/vda`, which matches the `virtio0` boot disk — a user supplying their own patch list **replaces** that default and must re-include the install disk. Both are `nullable = false`, which matters: they are consumed through `concat()`, and `concat` errors on a null argument.

`var.control_machine_config_patches_by_node` / `var.worker_machine_config_patches_by_node` are maps keyed by node name, appended *after* the shared lists so a node can override shared values. A key that matches no node is silently ignored (`lookup(..., [])`). Worker extra disks (`var.worker_extra_disks`) are attached via a `dynamic "disk"` block starting at `virtio1` (`interface = "virtio${disk.key+1}"`), so they never collide with the boot disk.

### Provider resource naming

bpg/proxmox >= 0.100.0 renamed its Framework resources from `proxmox_virtual_environment_*` to
`proxmox_*`; both work, but the long names emit a deprecation warning. This module uses the
short names where they exist (`proxmox_download_file`, `data.proxmox_datastores`) and expects
`terraform validate` to be warning-free.

`proxmox_virtual_environment_vm` is the exception: it is the older SDK-based resource and has
**no** short alias. `proxmox_vm` is the renamed `proxmox_virtual_environment_vm2`, a different
and incompatible resource (14 attributes vs 40). Do not "modernize" it.

### Breaking changes are documented, not engineered around

`talos_image` was renamed *and* re-keyed in 1.0.0, which forces replacement of every VM for
anyone upgrading in place. The deliberate call was to keep the module clean for new users and
document the hazard in a versioned upgrade guide rather than carry a compatibility shim. Two facts that
guide belongs on: `terraform state mv` cannot move between resource types, and a single
`moved` block can cross both the type change and the re-key (verified). When you next make a
breaking change here, add an `UPGRADE-<version>.md`, link it from the README with an
absolute GitHub URL (relative links do not resolve on the Terraform Registry), and bump the
major version.

## References

- Published module: https://registry.terraform.io/modules/bbtechsys/talos/proxmox/latest
- Design/usage write-up (PXE + Terraform): https://bbtechsystems.com/blog/k8s-with-pxe-tf/
