# terraform-proxmox-talos

Terraform module to provision Talos Linux Kubernetes clusters with Proxmox

## Example usage

```bash
export PROXMOX_VE_USERNAME="root@pam"
export PROXMOX_VE_PASSWORD="super-secret"
```

```terraform
terraform {
  required_providers {
    proxmox = {
      source = "bpg/proxmox"
      version = "~> 0.75.0"
    }
    talos = {
      source = "siderolabs/talos"
      version = "~> 0.7.1"
    }
  }
}

provider "proxmox" {
  endpoint = "https://192.168.1.21:8006/"
  insecure = true
}

module "talos" {
    source  = "bbtechsys/talos/proxmox"
    version = "0.1.5"
    talos_cluster_name = "test-cluster"
    talos_version = "1.9.5"
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

Check out our [blog post](https://bbtechsystems.com/blog/k8s-with-pxe-tf/) for more details on using this module.

Copyright (c) 2024 BB Tech Systems LLC

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
|------|---------|
| <a name="requirement_proxmox"></a> [proxmox](#requirement\_proxmox) | >= 0.68.0 |
| <a name="requirement_talos"></a> [talos](#requirement\_talos) | >= 0.6.1 |

## Providers

| Name | Version |
|------|---------|
| <a name="provider_proxmox"></a> [proxmox](#provider\_proxmox) | >= 0.68.0 |
| <a name="provider_talos"></a> [talos](#provider\_talos) | >= 0.6.1 |

## Modules

No modules.

## Resources

| Name | Type |
|------|------|
| [proxmox_virtual_environment_download_file.talos_image](https://registry.terraform.io/providers/bpg/proxmox/latest/docs/resources/virtual_environment_download_file) | resource |
| [proxmox_virtual_environment_vm.talos_control_vm](https://registry.terraform.io/providers/bpg/proxmox/latest/docs/resources/virtual_environment_vm) | resource |
| [proxmox_virtual_environment_vm.talos_worker_vm](https://registry.terraform.io/providers/bpg/proxmox/latest/docs/resources/virtual_environment_vm) | resource |
| [talos_cluster_kubeconfig.talos_kubeconfig](https://registry.terraform.io/providers/siderolabs/talos/latest/docs/resources/cluster_kubeconfig) | resource |
| [talos_machine_bootstrap.talos_bootstrap](https://registry.terraform.io/providers/siderolabs/talos/latest/docs/resources/machine_bootstrap) | resource |
| [talos_machine_configuration_apply.talos_control_mc_apply](https://registry.terraform.io/providers/siderolabs/talos/latest/docs/resources/machine_configuration_apply) | resource |
| [talos_machine_configuration_apply.talos_worker_mc_apply](https://registry.terraform.io/providers/siderolabs/talos/latest/docs/resources/machine_configuration_apply) | resource |
| [talos_machine_secrets.talos_secrets](https://registry.terraform.io/providers/siderolabs/talos/latest/docs/resources/machine_secrets) | resource |
| [talos_client_configuration.talos_client_config](https://registry.terraform.io/providers/siderolabs/talos/latest/docs/data-sources/client_configuration) | data source |
| [talos_machine_configuration.control_mc](https://registry.terraform.io/providers/siderolabs/talos/latest/docs/data-sources/machine_configuration) | data source |
| [talos_machine_configuration.worker_mc](https://registry.terraform.io/providers/siderolabs/talos/latest/docs/data-sources/machine_configuration) | data source |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_control_machine_config_patches"></a> [control\_machine\_config\_patches](#input\_control\_machine\_config\_patches) | List of YAML patches to apply to the control machine configuration | `list(string)` | <pre>[<br/>  "machine:\n  install:\n    disk: \"/dev/vda\"\n"<br/>]</pre> | no |
| <a name="input_control_nodes"></a> [control\_nodes](#input\_control\_nodes) | Map of talos control node names to proxmox node names | `map(string)` | n/a | yes |
| <a name="input_proxmox_control_vm_cores"></a> [proxmox\_control\_vm\_cores](#input\_proxmox\_control\_vm\_cores) | Number of CPU cores for the control VMs | `number` | `4` | no |
| <a name="input_proxmox_control_vm_disk_size"></a> [proxmox\_control\_vm\_disk\_size](#input\_proxmox\_control\_vm\_disk\_size) | Proxmox control VM disk size in GB | `number` | `32` | no |
| <a name="input_proxmox_control_vm_memory"></a> [proxmox\_control\_vm\_memory](#input\_proxmox\_control\_vm\_memory) | Memory in MB for the control VMs | `number` | `4096` | no |
| <a name="input_proxmox_image_datastore"></a> [proxmox\_image\_datastore](#input\_proxmox\_image\_datastore) | Datastore to put the VM hard drive images | `string` | `"local-lvm"` | no |
| <a name="input_proxmox_iso_datastore"></a> [proxmox\_iso\_datastore](#input\_proxmox\_iso\_datastore) | Datastore to put the qcow2 image | `string` | `"local"` | no |
| <a name="input_proxmox_network_bridge"></a> [proxmox\_network\_bridge](#input\_proxmox\_network\_bridge) | Proxmox network Bridge | `string` | `"vmbr0"` | no |
| <a name="input_proxmox_network_vlan_id"></a> [proxmox\_network\_vlan\_id](#input\_proxmox\_network\_vlan\_id) | Proxmox network VLAN ID | `number` | `null` | no |
| <a name="input_proxmox_vm_type"></a> [proxmox\_vm\_type](#input\_proxmox\_vm\_type) | Proxmox emulated CPU type, x86-64-v2-AES recommended | `string` | `"x86-64-v2-AES"` | no |
| <a name="input_proxmox_worker_vm_cores"></a> [proxmox\_worker\_vm\_cores](#input\_proxmox\_worker\_vm\_cores) | Number of CPU cores for the worker VMs | `number` | `4` | no |
| <a name="input_proxmox_worker_vm_disk_size"></a> [proxmox\_worker\_vm\_disk\_size](#input\_proxmox\_worker\_vm\_disk\_size) | Proxmox worker VM disk size in GB | `number` | `100` | no |
| <a name="input_proxmox_worker_vm_memory"></a> [proxmox\_worker\_vm\_memory](#input\_proxmox\_worker\_vm\_memory) | Memory in MB for the worker VMs | `number` | `4096` | no |
| <a name="input_talos_arch"></a> [talos\_arch](#input\_talos\_arch) | Architecture of Talos to use | `string` | `"amd64"` | no |
| <a name="input_talos_cluster_name"></a> [talos\_cluster\_name](#input\_talos\_cluster\_name) | Name of the Talos cluster | `string` | n/a | yes |
| <a name="input_talos_schematic_id"></a> [talos\_schematic\_id](#input\_talos\_schematic\_id) | Schematic ID for the Talos cluster | `string` | `"ce4c980550dd2ab1b17bbf2b08801c7eb59418eafe8f279833297925d67c7515"` | no |
| <a name="input_talos_version"></a> [talos\_version](#input\_talos\_version) | Version of Talos to use | `string` | n/a | yes |
| <a name="input_worker_extra_disks"></a> [worker\_extra\_disks](#input\_worker\_extra\_disks) | Map of talos worker node name to a list of extra disk blocks for the VMs | <pre>map(list(object({<br/>        datastore_id = string<br/>        size         = number<br/>        file_format  = optional(string)<br/>        file_id      = optional(string)<br/>    })))</pre> | `{}` | no |
| <a name="input_worker_machine_config_patches"></a> [worker\_machine\_config\_patches](#input\_worker\_machine\_config\_patches) | List of YAML patches to apply to the worker machine configuration | `list(string)` | <pre>[<br/>  "machine:\n  install:\n    disk: \"/dev/vda\"\n"<br/>]</pre> | no |
| <a name="input_worker_nodes"></a> [worker\_nodes](#input\_worker\_nodes) | Map of talos worker node names to proxmox node names | `map(string)` | n/a | yes |

## Outputs

| Name | Description |
|------|-------------|
| <a name="output_kubeconfig"></a> [kubeconfig](#output\_kubeconfig) | Kubeconfig file |
| <a name="output_talos_config"></a> [talos\_config](#output\_talos\_config) | Talos configuration file |
<!-- END_TF_DOCS -->
