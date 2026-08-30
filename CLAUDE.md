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

Ordering is entirely implicit via resource references; there is one explicit `depends_on` (kubeconfig on bootstrap).

### Two things that constrain most changes

**IP discovery depends on the QEMU guest agent and DHCP.** Node IPs are read as `proxmox_virtual_environment_vm.…[key].ipv4_addresses[7][0]` — index 7 is the position of Talos's primary NIC in the guest-agent interface list. There is no static-IP support; the intended pattern is to pin addresses in DHCP by MAC using `var.control_plane_mac_addresses` / `var.worker_mac_addresses`. Consequently:
- The Talos schematic **must** include the `qemu-guest-agent` extension (the default `talos_schematic_id` does), or the apply hangs/fails with no IPs.
- Anything touching networking (extra NICs, VLAN changes) can shift that `[7]` index.

**The cluster endpoint is a single point of failure by design.** `cluster_endpoint` for both machine configurations is `https://${local.primary_control_node_ip}:6443`, where the primary is `keys(var.control_nodes)[0]`. There is no VIP or load balancer. Two `TODO` comments in `main.tf` mark this as a known limitation — if adding an override, it must be a new optional variable that defaults to current behavior.

### Machine config patching

Users customize Talos via `var.control_machine_config_patches` / `var.worker_machine_config_patches` (lists of YAML strings). Both default to a patch setting `machine.install.disk = /dev/vda`, which matches the `virtio0` boot disk — a user supplying their own patch list **replaces** that default and must re-include the install disk. Worker extra disks (`var.worker_extra_disks`) are attached via a `dynamic "disk"` block starting at `virtio1` (`interface = "virtio${disk.key+1}"`), so they never collide with the boot disk.

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
document the hazard in `UPGRADE-1.0.md` rather than carry a compatibility shim. Two facts that
guide belongs on: `terraform state mv` cannot move between resource types, and a single
`moved` block can cross both the type change and the re-key (verified). When you next make a
breaking change here, add an `UPGRADE-<version>.md`, link it from the README with an
absolute GitHub URL (relative links do not resolve on the Terraform Registry), and bump the
major version.

## References

- Published module: https://registry.terraform.io/modules/bbtechsys/talos/proxmox/latest
- Design/usage write-up (PXE + Terraform): https://bbtechsystems.com/blog/k8s-with-pxe-tf/
