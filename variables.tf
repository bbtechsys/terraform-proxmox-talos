# Copyright (c) 2024 BB Tech Systems LLC

variable "proxmox_iso_datastore" {
    description = "Datastore to put the qcow2 image. If it is not shared across the Proxmox cluster it must exist, and accept \"iso\" content, on every host named in control_nodes and worker_nodes"
    type        = string
    default     = "local"
}

variable "proxmox_iso_datastore_shared" {
    # A shared datastore holds one copy of the image for the whole cluster; a
    # node-local one needs a copy on each host running cluster nodes.
    description = "Override whether proxmox_iso_datastore is shared across the Proxmox cluster. Leave null to read the datastore's shared flag from Proxmox, and set it only when that flag does not match reality"
    type        = bool
    default     = null
}

variable "talos_image_upload_timeout" {
    description = "Timeout in seconds for downloading the Talos image onto a Proxmox host"
    type        = number
    default     = 600
}

variable "talos_platform" {
    # "metal" boots the plain disk image and gets its address from DHCP (or from a
    # config patch applied later). "nocloud" boots the Image Factory's nocloud image,
    # which reads networking from the cloud-init drive Proxmox generates — the only way
    # to give a node a static address before Terraform first talks to it. Pair it with
    # node_network and control_node_addresses / worker_node_addresses.
    description = "Talos Image Factory platform: \"metal\" (default) or \"nocloud\" for cloud-init network configuration"
    type        = string
    default     = "metal"
    nullable    = false

    validation {
        condition     = contains(["metal", "nocloud"], var.talos_platform)
        error_message = "talos_platform must be \"metal\" or \"nocloud\"."
    }
}


variable "node_network" {
    # Applied to every node that has an entry in control_node_addresses or
    # worker_node_addresses. Only used when talos_platform is "nocloud".
    description = "Static network settings for nodes with a declared address, written to their cloud-init network config"
    type = object({
        prefix_length = number
        gateway       = string
        nameservers   = optional(list(string), [])
    })
    default = null
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

variable "control_node_addresses" {
    # Set this when nodes are statically addressed rather than served by DHCP. The module
    # then uses these addresses instead of discovering them through the QEMU guest agent,
    # and does not wait for the agent to report an IP before continuing.
    # You must still configure the address inside Talos itself, via a config patch — see
    # the static addressing section of the README.
    description = "Map of control node name to its IP address, for nodes that are not assigned an address by DHCP"
    type        = map(string)
    default     = {}
    nullable    = false
}

variable "worker_node_addresses" {
    # See control_node_addresses.
    description = "Map of worker node name to its IP address, for nodes that are not assigned an address by DHCP"
    type        = map(string)
    default     = {}
    nullable    = false
}

variable "control_plane_mac_addresses" {
    description = "Map of control plane node names to MAC addresses for static IP assignment via DHCP"
    type        = map(string)
    default     = {}
    nullable    = false
}

variable "worker_mac_addresses" {
    description = "Map of worker node names to MAC addresses for static IP assignment via DHCP"
    type        = map(string)
    default     = {}
    nullable    = false
}

variable "talos_cluster_name" {
    description = "Name of the Talos cluster"
    type        = string
}

variable "wait_for_cluster_health" {
    # talos_cluster_kubeconfig returns as soon as bootstrap completes, which is before
    # kube-apiserver is serving — and with a VIP, before the endpoint address even
    # exists. Turning this on closes that gap, at a real cost: the health check is a
    # data source, so it is re-read on every refresh and plan, not only on create. A
    # cluster that is temporarily degraded (a node down for maintenance, a control node
    # mid-reboot) will then fail `terraform plan` until it recovers. Off by default for
    # that reason; turn it on for first provisioning and CI, where the guarantee matters
    # more than being able to plan against a sick cluster.
    description = "Wait for the cluster to become healthy before apply completes, so the kubeconfig output is usable when Terraform returns. Note that this is re-checked on every plan, so a degraded cluster will fail planning"
    type        = bool
    default     = false
    nullable    = false
}

variable "cluster_health_skip_kubernetes_checks" {
    # Needed by any cluster that disables the built-in CNI (cluster.network.cni.name =
    # "none") to install its own — nodes stay NotReady until that CNI is deployed, which
    # happens after Terraform is done, so the Kubernetes checks would never pass.
    description = "Skip the Kubernetes checks in the health wait, keeping only the etcd and boot checks. Required if you disable the built-in CNI"
    type        = bool
    default     = false
    nullable    = false
}

variable "cluster_health_timeout" {
    # Null uses the provider default. A 5-node cluster took ~4.5 minutes to go healthy,
    # so larger clusters or slow storage can need more.
    description = "How long to wait for the cluster to become healthy, as a duration such as \"20m\". Null uses the provider default"
    type        = string
    default     = null
}

variable "talos_cluster_endpoint" {
    # When null, the endpoint defaults to https://<first control node IP>:6443,
    # which is a single point of failure. Set this to a shared VIP or a
    # load-balancer/proxy address (e.g. https://10.0.0.10:6443) for an HA endpoint.
    # If using a Talos shared VIP, also define it via control_machine_config_patches
    # or control_machine_config_patches_by_node (machine.network.interfaces[].vip.ip).
    description = "Kubernetes API cluster endpoint (e.g. https://<vip>:6443). Defaults to the first control node's IP."
    type        = string
    default     = null

    validation {
        # "" is allowed and means "use the default", which is how coalesce below treats
        # it — consumers wire this from their own optional variables. A port is
        # deliberately not required: 443 is legitimate behind a load balancer. A single
        # trailing slash is allowed, since that is how a kubeconfig writes a server URL.
        # Rejected: no scheme, embedded whitespace (which coalesce does NOT treat as
        # empty, unlike ""), a path, a query string, or a fragment.
        condition     = var.talos_cluster_endpoint == null || var.talos_cluster_endpoint == "" || can(regex("^https://[^/?#[:space:]]+/?$", var.talos_cluster_endpoint))
        error_message = "talos_cluster_endpoint must be an https:// URL with no path, query or fragment, for example \"https://10.0.0.10:6443\". Talos assumes port 443 when none is given, so a port is usually wanted."
    }
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
    nullable    = false
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
    nullable    = false
}

variable "control_machine_config_patches_by_node" {
    # Patches here are appended AFTER control_machine_config_patches, so they can
    # override shared values. Use for per-node settings such as hostnames, node
    # labels or kubelet args. Do NOT set static addresses here: node IPs are
    # discovered through the QEMU guest agent, so a static-address patch can move a
    # node out from under that discovery. Pin a mac_address + DHCP reservation instead.
    # Example:
    # control_machine_config_patches_by_node = {
    #   "talos-control-0" = [yamlencode({ machine = { network = { hostname = "cp0" } } })]
    # }
    description = "Map of control node name to a list of extra YAML patches applied after the shared control patches"
    type        = map(list(string))
    default     = {}
    nullable    = false
}

variable "worker_machine_config_patches_by_node" {
    # Patches here are appended AFTER worker_machine_config_patches, so they can
    # override shared values. Use for per-node settings such as hostnames, node
    # labels or kubelet args. Do NOT set static addresses here: node IPs are
    # discovered through the QEMU guest agent, so a static-address patch can move a
    # node out from under that discovery. Pin a mac_address + DHCP reservation instead.
    description = "Map of worker node name to a list of extra YAML patches applied after the shared worker patches"
    type        = map(list(string))
    default     = {}
    nullable    = false
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
