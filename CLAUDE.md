# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A **published Terraform module** (`bbtechsys/talos/proxmox` on the Terraform Registry) that provisions a Talos Linux Kubernetes cluster on Proxmox VE. The repository root *is* the module — there is no `modules/` directory, no example subdirectory, and no root-level provider config in git. Consumers supply their own `provider "proxmox"` block and credentials (`PROXMOX_VE_USERNAME` / `PROXMOX_VE_PASSWORD` env vars).

Because it ships as a module, treat `variables.tf` and `outputs.tf` as the public API: renaming or removing a variable/output is a breaking change for downstream users, and README example usage should stay in sync with them.

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

1. **`proxmox_virtual_environment_download_file.talos_image`** pulls a qcow2 from `factory.talos.dev` built from `var.talos_schematic_id` + `var.talos_version` + `var.talos_arch`. Downloaded once, onto the *first* control node's Proxmox host, and shared as the boot disk `file_id` by every VM.
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

## References

- Published module: https://registry.terraform.io/modules/bbtechsys/talos/proxmox/latest
- Design/usage write-up (PXE + Terraform): https://bbtechsystems.com/blog/k8s-with-pxe-tf/
