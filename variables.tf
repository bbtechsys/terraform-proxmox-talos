# Copyright (c) 2024 BB Tech Systems LLC

variable "proxmox_iso_datastore" {
    description = "Datastore to put the qcow2 image"
    type        = string
    default     = "local"
}

variable "proxmox_image_datastore" {
    description = "Datastore to put the VM hard drive images"
    type        = string
    default     = "local-lvm"
}

variable "proxmox_control_vm_cores" {
    description = "Number of CPU cores for the control VMs"
    type        = number
    default     = 4
}

variable "proxmox_worker_vm_cores" {
    description = "Number of CPU cores for the worker VMs"
    type        = number
    default     = 4
}

variable "proxmox_control_vm_memory" {
    description = "Memory in MB for the control VMs"
    type        = number
    default     = 4096
}

variable "proxmox_worker_vm_memory" {
    description = "Memory in MB for the worker VMs"
    type        = number
    default     = 4096
}

variable "proxmox_vm_type" {
    description = "Proxmox emulated CPU type, x86-64-v2-AES recommended"
    type        = string
    default     = "x86-64-v2-AES"
}

variable "proxmox_control_vm_disk_size" {
    description = "Proxmox control VM disk size in GB"
    type        = number
    default     = 32
}

variable "proxmox_worker_vm_disk_size" {
    description = "Proxmox worker VM disk size in GB"
    type        = number
    default     = 100
}

variable "proxmox_network_vlan_id" {
    description = "Proxmox network VLAN ID"
    type        = number
    default     = null
}
variable "proxmox_network_bridge" {
  description = "Proxmox network Bridge"
  type = string
  default = "vmbr0"
}

variable "talos_cluster_name" {
    description = "Name of the Talos cluster"
    type        = string
}

variable "proxmox_control_pool_id" {
    description = "Proxmox control VM pool ID"
    type = string
    default = null
}

variable "proxmox_worker_pool_id" {
    description = "Proxmox worker VM pool ID"
    type = string
    default = null
}

variable "talos_schematic_id" {
    # Generate your own at https://factory.talos.dev/
    # The this id has these extensions:
    # qemu-guest-agent (required)
    # If you make your own make sure you check this extension
    # The ID is independent of the version and architecture of the image
    description = "Schematic ID for the Talos cluster"
    type        = string
    default     = "ce4c980550dd2ab1b17bbf2b08801c7eb59418eafe8f279833297925d67c7515"
}

variable "talos_version" {
    description = "Version of Talos to use"
    type        = string
}

variable "talos_arch" {
    description = "Architecture of Talos to use"
    type        = string
    default     = "amd64"
}

# Theses two variables are maps that control how many control and worker nodes are created
# and what their names are. The keys are the talos node names and the values are the proxmox node names
# to create the VMs on.
# Example:
# control_nodes = {
#   "talos-control-0" = "proxmox-node-0"
# }
# worker_nodes = {
#   "talos-worker-0" = "proxmox-node-0"
#   "talos-worker-1" = "proxmox-node-0"
# }
variable "control_nodes" {
    description = "Map of talos control node names to proxmox node names"
    type        = map(string)
}

variable "worker_nodes" {
    description = "Map of talos worker node names to proxmox node names"
    type        = map(string)
}

variable "control_machine_config_patches" {
    description = "List of YAML patches to apply to the control machine configuration"
    type        = list(string)
    default     = [
<<EOT
machine:
  install:
    disk: "/dev/vda"
EOT
    ]
}

variable "worker_machine_config_patches" {
    description = "List of YAML patches to apply to the worker machine configuration"
    type        = list(string)
    default     = [
<<EOT
machine:
  install:
    disk: "/dev/vda"
EOT
    ]
}

variable "worker_extra_disks" {
    # This allows for extra disks to be added to the worker VMs
    # TODO - Should we allow other things like host PCI devices as well E.g., GPUs?
    description = "Map of talos worker node name to a list of extra disk blocks for the VMs"
    type        = map(list(object({
        datastore_id = string
        size         = number
        file_format  = optional(string)
        file_id      = optional(string)
    })))
    default     = {}
}
