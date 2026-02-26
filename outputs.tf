# Copyright (c) 2024 BB Tech Systems LLC

output "talos_config" {
    description = "Talos configuration file"
    value       = data.talos_client_configuration.talos_client_config.talos_config
    sensitive   = true
}

output "kubeconfig" {
    description = "Kubeconfig file"
    value       = talos_cluster_kubeconfig.talos_kubeconfig.kubeconfig_raw
    sensitive   = true
}

output "control_plane_ips" {
    description = "List of control plane node IPs"
    value       = local.control_node_ips
}

output "worker_ips" {
    description = "List of worker node IPs"
    value       = local.worker_node_ips
}

output "all_node_ips" {
    description = "List of all node IPs (control + workers)"
    value       = local.node_ips
}
