# 1.2 Upgrade Guide

What changes when moving from 1.1.x to 1.2.0 of `bbtechsys/talos/proxmox`.

There are no state moves and no forced replacements. But unlike [1.1](UPGRADE-1.1.md), this
release can make a configuration that previously applied cleanly **fail** — in three places,
each of which was previously failing silently or late. Read this before upgrading.

## Apply now waits for the cluster to be healthy

`terraform apply` used to return as soon as Talos handed over the kubeconfig, which happens
when bootstrap completes — before kube-apiserver is serving. In testing, `kubectl get nodes`
immediately after a successful apply returned `connection refused`, then `No resources found`,
and the nodes only reached `Ready` about 75 seconds later. With `talos_cluster_endpoint` set to
a Talos VIP it is worse: the VIP is not claimed until after bootstrap, so the kubeconfig named
an address that did not yet exist.

1.2 adds a `talos_cluster_health` check that the `kubeconfig` and `talos_config` outputs depend
on, so apply does not return until the cluster is actually serving.

**What this means for you:**

- `terraform apply && kubectl apply -f ...` now works without a sleep.
- Apply takes longer — the wait is however long your cluster needs to converge.
- A cluster that never becomes healthy now **fails the apply** instead of succeeding with
  credentials that do not work. This is the point, but it will surface problems that 1.1 hid.

To keep the old behavior:

```terraform
wait_for_cluster_health = false
```

## `talos_cluster_endpoint` is validated at plan time

Malformed values used to be accepted and land in every node's machine configuration. These now
fail at plan:

| Value | Why |
| --- | --- |
| `"10.0.0.10:6443"` | no scheme |
| `" "` | whitespace; `coalesce` only treats `""` as empty, so this did not fall back |
| `"https://10.0.0.10:6443/api"` | a path |

A port is **not** required — `https://api.example.com` is valid, since 443 is legitimate behind
a load balancer. Talos assumes 443 when no port is given, so include `:6443` if you meant it.

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

## New variable

| Variable | Default | Purpose |
| --- | --- | --- |
| `wait_for_cluster_health` | `true` | Block apply until the cluster is healthy, so the `kubeconfig` output is usable when Terraform returns. Set `false` for 1.1 behavior. |
