# 1.2 Upgrade Guide

What changes when moving from 1.1.x to 1.2.0 of `bbtechsys/talos/proxmox`.

There are no state moves and no forced replacements, and the one new behavior is opt-in. But
two plan-time checks are new, and both can reject a configuration that previously applied — in
each case one that was silently broken. Read those two sections before upgrading.

## Opt in to waiting for the cluster to be healthy

`terraform apply` returns as soon as Talos hands over the kubeconfig, which happens when
bootstrap completes — before kube-apiserver is serving. In testing, `kubectl get nodes`
immediately after a successful apply returned `connection refused`, then `No resources found`,
with nodes reaching `Ready` about 75 seconds later. With `talos_cluster_endpoint` set to a Talos
VIP it is worse: the VIP is not claimed until after bootstrap.

1.2 adds a `talos_cluster_health` check that the `kubeconfig` output can depend on:

```terraform
wait_for_cluster_health = true
```

**It defaults to `false`, so nothing changes unless you opt in.** The check is a data source,
which Terraform re-reads on every refresh and plan — so with it on, a cluster that is
temporarily degraded fails `terraform plan` until it recovers. That is a bad trade for routine
operations and a good one for first provisioning and CI, so it is yours to choose.

If you turn it on:

- **Disabling the built-in CNI requires `cluster_health_skip_kubernetes_checks = true`.** With
  `cluster.network.cni.name = "none"` (the usual way to install Cilium) nodes stay `NotReady`
  until you deploy that CNI, which is after Terraform finishes, so the Kubernetes checks would
  never pass and every apply would fail.
- **`cluster_health_timeout`** takes a duration such as `"20m"`. A five-node cluster took about
  four and a half minutes, so the provider default is not a large margin.
- The check talks to the control nodes, never to `talos_cluster_endpoint`, because Talos
  documents that a VIP must not be used as a Talos API endpoint. With a VIP, a healthy result
  means etcd and kube-apiserver are up on the nodes; the VIP claim follows from the same etcd
  election but is not explicitly waited on.

## `talos_cluster_endpoint` is validated at plan time

Malformed values used to be accepted and land in every node's machine configuration. These now
fail at plan:

| Value | Why |
| --- | --- |
| `"10.0.0.10:6443"` | no scheme |
| `" "` | whitespace; `coalesce` only treats `""` as empty, so this did not fall back |
| `"https://10.0.0.10:6443/api"` | a path |
| `"https://10.0.0.10:6443?debug=1"` | a query string |
| `"https://10.0.0.10:6443#x"` | a fragment |

Still accepted: `""` (means "use the default", as before), a trailing slash
(`https://10.0.0.10:6443/`, which is how a kubeconfig writes a server URL), and no port at all
(`https://api.example.com`) — 443 is legitimate behind a load balancer. Talos assumes 443 when
no port is given, so include `:6443` if you meant it.

## `_by_node` patch keys must match a node

`control_machine_config_patches_by_node` and `worker_machine_config_patches_by_node` are read
with `lookup(..., [])`, so a key matching no node silently produced no patch and a successful
apply. A typo or a key left behind after renaming a node now fails at plan, naming the key:

```
worker_machine_config_patches_by_node has keys matching no entry in worker_nodes: ha-worker-O.
Patches under those keys would be silently dropped.
```

If this fires on upgrade, the patch was never being applied — fix the key or remove it.

## Ordering is now explicit

Two dependencies that were previously left to chance:

- **Bootstrap now waits for the control plane to be configured.**
  `talos_machine_bootstrap` referenced only the node's IP and the machine secrets, so nothing
  ordered it after `talos_machine_configuration_apply`. It worked on graph luck.
- **Workers are now configured after bootstrap.** A worker's configuration names the cluster
  endpoint, and with a VIP that address does not exist until bootstrap completes, so workers
  would sit retrying their API join.

No action needed. Apply is marginally slower because work that overlapped is now ordered;
bootstrap measured about 8 seconds on a live cluster, so the difference is small.

## New variables

| Variable | Default | Purpose |
| --- | --- | --- |
| `wait_for_cluster_health` | `false` | Block apply until the cluster is healthy, so the `kubeconfig` output is usable when Terraform returns. Off by default because it is re-checked on every plan. |
| `cluster_health_skip_kubernetes_checks` | `false` | Keep only the etcd and boot checks. Required if you disable the built-in CNI. |
| `cluster_health_timeout` | `null` | How long to wait for health, e.g. `"20m"`. Null uses the provider default. |
