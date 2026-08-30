# Copyright (c) 2024 BB Tech Systems LLC

locals {
    primary_proxmox_host = values(var.control_nodes)[0]
    proxmox_hosts        = toset(concat(values(var.control_nodes), values(var.worker_nodes)))

    # The QEMU guest agent reports every interface Talos creates — lo, bond0, dummy0,
    # teql0, tunl0, sit0, ip6tnl0 — before the real NIC, so the NIC has historically
    # landed at index 7. That is an accident of how many dummy interfaces Talos happens
    # to make, and it shifts the moment one is added or removed. Select the first
    # interface that actually reports a routable IPv4 instead of trusting a position,
    # and take that interface's first address (so a Talos VIP, which is a second address
    # on the same NIC, is not mistaken for the node's own).
    # Interfaces belonging to the pod network. These report routable IPv4s too, so
    # without excluding them a node could be addressed on its CNI interface. Matched
    # by name prefix; bond*/dummy* are deliberately not listed, since a bonded NIC is
    # a legitimate primary interface.
    cni_interface_prefixes = ["flannel", "cni", "cali", "veth", "docker", "kube-"]

    # Only for nodes actually using discovery: a node with a declared address has
    # wait_for_ip disabled, so the agent reports nothing and these lists are empty.
    control_node_discovered_ip = {
        for name, vm in proxmox_virtual_environment_vm.talos_control_vm :
        name => [
            for index, interface in vm.network_interface_names : vm.ipv4_addresses[index][0]
            if length(vm.ipv4_addresses[index]) > 0
                && !startswith(vm.ipv4_addresses[index][0], "127.")
                && !startswith(vm.ipv4_addresses[index][0], "169.254.")
                && length([for prefix in local.cni_interface_prefixes : true if startswith(interface, prefix)]) == 0
        ][0]
        if !contains(keys(var.control_node_addresses), name)
    }
    # Only for nodes actually using discovery: a node with a declared address has
    # wait_for_ip disabled, so the agent reports nothing and these lists are empty.
    worker_node_discovered_ip = {
        for name, vm in proxmox_virtual_environment_vm.talos_worker_vm :
        name => [
            for index, interface in vm.network_interface_names : vm.ipv4_addresses[index][0]
            if length(vm.ipv4_addresses[index]) > 0
                && !startswith(vm.ipv4_addresses[index][0], "127.")
                && !startswith(vm.ipv4_addresses[index][0], "169.254.")
                && length([for prefix in local.cni_interface_prefixes : true if startswith(interface, prefix)]) == 0
        ][0]
        if !contains(keys(var.worker_node_addresses), name)
    }

    # A node's address comes from var.*_node_addresses when declared, otherwise from the
    # guest agent. A conditional rather than try(): try() would also swallow a genuine
    # discovery failure and report it as "no expression succeeded", hiding which half broke.
    control_node_ip = { for name in keys(var.control_nodes) :
        name => contains(keys(var.control_node_addresses), name)
            ? var.control_node_addresses[name]
            : local.control_node_discovered_ip[name]
    }
    worker_node_ip = { for name in keys(var.worker_nodes) :
        name => contains(keys(var.worker_node_addresses), name)
            ? var.worker_node_addresses[name]
            : local.worker_node_discovered_ip[name]
    }

    primary_control_node_ip = local.control_node_ip[keys(var.control_nodes)[0]]
    control_node_ips = [for name in keys(var.control_nodes) : local.control_node_ip[name]]
    worker_node_ips = [for name in keys(var.worker_nodes) : local.worker_node_ip[name]]
    node_ips = concat(
        local.control_node_ips,
        local.worker_node_ips
    )

    # Defaults to the first control node's IP for backward compatibility.
    # Set var.talos_cluster_endpoint to a VIP or load balancer for an HA endpoint.
    resolved_cluster_endpoint = coalesce(var.talos_cluster_endpoint, "https://${local.primary_control_node_ip}:6443")

    talos_image_url = "https://factory.talos.dev/image/${var.talos_schematic_id}/v${var.talos_version}/${var.talos_platform}-${var.talos_arch}.qcow2"
    # The metal name is deliberately left unsuffixed: changing it would change every
    # VM's disk.file_id, which is ForceNew, and replace existing clusters.
    talos_image_file_name = "${var.talos_cluster_name}-talos_linux-${var.talos_schematic_id}-${var.talos_version}-${var.talos_arch}${var.talos_platform == "metal" ? "" : "-${var.talos_platform}"}.img"

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

    # Nodes given their address by cloud-init at boot. Requires the nocloud platform
    # (the metal image has no cloud-init datasource), network settings, and a declared
    # address. Proxmox generates the cloud-init network data itself from ip_config, so
    # this needs no snippets datastore and no SSH access to the host.
    cloud_init_nodes = var.talos_platform != "nocloud" || var.node_network == null ? {} : merge(
        { for name, address in var.control_node_addresses : name => address
            if contains(keys(var.control_nodes), name) },
        { for name, address in var.worker_node_addresses : name => address
            if contains(keys(var.worker_nodes), name) },
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
        wait_for_ip {
            disabled = contains(keys(var.control_node_addresses), each.key)
        }
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
    dynamic "initialization" {
        for_each = contains(keys(local.cloud_init_nodes), each.key) ? [each.key] : []
        content {
            datastore_id = var.proxmox_image_datastore
            interface    = "ide2"
            type         = "nocloud"
            ip_config {
                ipv4 {
                    address = "${local.cloud_init_nodes[initialization.value]}/${var.node_network.prefix_length}"
                    gateway = var.node_network.gateway
                }
            }
            dynamic "dns" {
                for_each = length(var.node_network.nameservers) == 0 ? [] : [1]
                content {
                    servers = var.node_network.nameservers
                }
            }
        }
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
        wait_for_ip {
            disabled = contains(keys(var.worker_node_addresses), each.key)
        }
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
    dynamic "initialization" {
        for_each = contains(keys(local.cloud_init_nodes), each.key) ? [each.key] : []
        content {
            datastore_id = var.proxmox_image_datastore
            interface    = "ide2"
            type         = "nocloud"
            ip_config {
                ipv4 {
                    address = "${local.cloud_init_nodes[initialization.value]}/${var.node_network.prefix_length}"
                    gateway = var.node_network.gateway
                }
            }
            dynamic "dns" {
                for_each = length(var.node_network.nameservers) == 0 ? [] : [1]
                content {
                    servers = var.node_network.nameservers
                }
            }
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
    cluster_endpoint = local.resolved_cluster_endpoint
    machine_secrets  = talos_machine_secrets.talos_secrets.machine_secrets
}

data "talos_machine_configuration" "worker_mc" {
    cluster_name     = var.talos_cluster_name
    machine_type     = "worker"
    cluster_endpoint = local.resolved_cluster_endpoint
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
    node                        = local.control_node_ip[each.key]
    config_patches              = concat(
        var.control_machine_config_patches,
        lookup(var.control_machine_config_patches_by_node, each.key, [])
    )
}

resource "talos_machine_configuration_apply" "talos_worker_mc_apply" {
    for_each = var.worker_nodes
    client_configuration        = talos_machine_secrets.talos_secrets.client_configuration
    machine_configuration_input = data.talos_machine_configuration.worker_mc.machine_configuration
    node                        = local.worker_node_ip[each.key]
    config_patches              = concat(
        var.worker_machine_config_patches,
        lookup(var.worker_machine_config_patches_by_node, each.key, [])
    )
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