# Copyright (c) 2024 BB Tech Systems LLC

locals {
    primary_proxmox_host = values(var.control_nodes)[0]
    proxmox_hosts        = toset(concat(values(var.control_nodes), values(var.worker_nodes)))

    primary_control_node_ip = proxmox_virtual_environment_vm.talos_control_vm[keys(var.control_nodes)[0]].ipv4_addresses[7][0]
    control_node_ips = [for vm in keys(var.control_nodes) : proxmox_virtual_environment_vm.talos_control_vm[vm].ipv4_addresses[7][0]]
    worker_node_ips = [for vm in keys(var.worker_nodes) : proxmox_virtual_environment_vm.talos_worker_vm[vm].ipv4_addresses[7][0]]
    node_ips = concat(
        local.control_node_ips,
        local.worker_node_ips
    )

    talos_image_url       = "https://factory.talos.dev/image/${var.talos_schematic_id}/v${var.talos_version}/metal-${var.talos_arch}.qcow2"
    talos_image_file_name = "${var.talos_cluster_name}-talos_linux-${var.talos_schematic_id}-${var.talos_version}-${var.talos_arch}.img"

    iso_datastores = {
        for host, result in data.proxmox_datastores.iso :
        host => { for datastore in result.datastores : datastore.id => datastore }
    }

    # A downloaded file's Proxmox volume ID is <datastore>:iso/<file_name> — it has no
    # node component. On a cluster-shared datastore (NFS, CIFS, CephFS, a ZFS pool
    # flagged shared) one download is therefore visible from every host, and a second
    # copy would collide with it. A node-local datastore such as the "local" default
    # needs its own copy of the image on each host instead.
    iso_datastore_shared = coalesce(
        var.proxmox_iso_datastore_shared,
        try(local.iso_datastores[local.primary_proxmox_host][var.proxmox_iso_datastore].shared, false),
        false
    )

    talos_image_hosts = local.iso_datastore_shared ? toset([local.primary_proxmox_host]) : local.proxmox_hosts

    # Which copy of the image each Proxmox host boots from: its own when the datastore is
    # node-local, the single cluster-wide one when it is shared.
    talos_image_ids = {
        for host in local.proxmox_hosts :
        host => proxmox_download_file.talos_image[local.iso_datastore_shared ? local.primary_proxmox_host : host].id
    }
}

data "proxmox_datastores" "iso" {
    for_each  = local.proxmox_hosts
    node_name = each.key
}

resource "proxmox_download_file" "talos_image" {
    for_each       = local.talos_image_hosts
    content_type   = "iso"
    datastore_id   = var.proxmox_iso_datastore
    node_name      = each.key
    url            = local.talos_image_url
    file_name      = local.talos_image_file_name
    upload_timeout = var.talos_image_upload_timeout

    lifecycle {
        precondition {
            condition     = contains(tolist(try(local.iso_datastores[each.key][var.proxmox_iso_datastore].content_types, [])), "iso")
            error_message = "Datastore \"${var.proxmox_iso_datastore}\" (var.proxmox_iso_datastore) must exist on Proxmox host \"${each.key}\" and accept \"iso\" content, so the Talos image can be downloaded there."
        }
    }
}

resource "proxmox_virtual_environment_vm" "talos_control_vm" {
    for_each  = var.control_nodes
    name      = each.key
    node_name = each.value
    pool_id = var.proxmox_control_pool_id
    agent {
        enabled = true
    }
    cpu {
        cores = var.proxmox_control_vm_cores
        type  = var.proxmox_vm_type
    }
    memory {
        dedicated = var.proxmox_control_vm_memory
        floating  = var.proxmox_control_vm_memory
    }
    disk {
        datastore_id = var.proxmox_image_datastore
        file_id      = local.talos_image_ids[each.value]
        interface    = "virtio0"
        iothread     = true
        discard      = "on"
        size         = var.proxmox_control_vm_disk_size
    }
    network_device {
        vlan_id     = var.proxmox_network_vlan_id
        bridge      = var.proxmox_network_bridge
        mac_address = lookup(var.control_plane_mac_addresses, each.key, null)
    }
    operating_system {
        type = "l26"
    }
}

resource "proxmox_virtual_environment_vm" "talos_worker_vm" {
    for_each  = var.worker_nodes
    name      = each.key
    node_name = each.value
    pool_id = var.proxmox_worker_pool_id
    agent {
        enabled = true
    }
    cpu {
        cores = var.proxmox_worker_vm_cores
        type  = var.proxmox_vm_type
    }
    memory {
        dedicated = var.proxmox_worker_vm_memory
        floating  = var.proxmox_worker_vm_memory
    }
    disk {
        datastore_id = var.proxmox_image_datastore
        file_id      = local.talos_image_ids[each.value]
        interface    = "virtio0"
        iothread     = true
        discard      = "on"
        size         = var.proxmox_worker_vm_disk_size
    }
    network_device {
        vlan_id     = var.proxmox_network_vlan_id
        bridge      = var.proxmox_network_bridge
        mac_address = lookup(var.worker_mac_addresses, each.key, null)
    }
    dynamic "disk" {
        for_each = lookup(var.worker_extra_disks, each.key, [])
        content {
            datastore_id = disk.value.datastore_id
            file_format  = disk.value.file_format
            file_id      = disk.value.file_id
            interface    = "virtio${disk.key+1}"
            iothread     = true
            discard      = "on"
            size         = disk.value.size
        }

    }
    operating_system {
        type = "l26"
    }
}

resource "talos_machine_secrets" "talos_secrets" {}

data "talos_machine_configuration" "control_mc" {
    cluster_name     = var.talos_cluster_name
    machine_type     = "controlplane"
    # TODO - Should we allow the user to override this?
    # This is a single point of failure but without a proxy or load balancer
    # it is required to be a single point of failure.
    cluster_endpoint = "https://${local.primary_control_node_ip}:6443"
    machine_secrets  = talos_machine_secrets.talos_secrets.machine_secrets
}

data "talos_machine_configuration" "worker_mc" {
    cluster_name     = var.talos_cluster_name
    machine_type     = "worker"
    # TODO - Should we allow the user to override this?
    # This is a single point of failure but without a proxy or load balancer
    # it is required to be a single point of failure.
    cluster_endpoint = "https://${local.primary_control_node_ip}:6443"
    machine_secrets  = talos_machine_secrets.talos_secrets.machine_secrets
}

data "talos_client_configuration" "talos_client_config" {
    cluster_name         = var.talos_cluster_name
    client_configuration = talos_machine_secrets.talos_secrets.client_configuration
    endpoints            = local.control_node_ips
    nodes                = local.node_ips
}

resource "talos_machine_configuration_apply" "talos_control_mc_apply" {
    for_each = var.control_nodes
    client_configuration        = talos_machine_secrets.talos_secrets.client_configuration
    machine_configuration_input = data.talos_machine_configuration.control_mc.machine_configuration
    node                        = proxmox_virtual_environment_vm.talos_control_vm[each.key].ipv4_addresses[7][0]
    config_patches              = var.control_machine_config_patches
}

resource "talos_machine_configuration_apply" "talos_worker_mc_apply" {
    for_each = var.worker_nodes
    client_configuration        = talos_machine_secrets.talos_secrets.client_configuration
    machine_configuration_input = data.talos_machine_configuration.worker_mc.machine_configuration
    node                        = proxmox_virtual_environment_vm.talos_worker_vm[each.key].ipv4_addresses[7][0]
    config_patches              = var.worker_machine_config_patches
}

# You only need to bootstrap 1 control node, we pick the first one
resource "talos_machine_bootstrap" "talos_bootstrap" {
    node                 = local.primary_control_node_ip
    client_configuration = talos_machine_secrets.talos_secrets.client_configuration
}

resource "talos_cluster_kubeconfig" "talos_kubeconfig" {
    depends_on   = [
        talos_machine_bootstrap.talos_bootstrap
    ]
    client_configuration = talos_machine_secrets.talos_secrets.client_configuration
    node                 = local.primary_control_node_ip
}