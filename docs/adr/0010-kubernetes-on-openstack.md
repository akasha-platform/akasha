---
status: accepted
date: 2026-11-08
decision-makers: dhuy21
---

# Kubernetes: K3s on Nova with OpenStack integrations

## Context and Problem Statement

Kubernetes must run on OpenStack VMs within ~10–12 GB of guest RAM, host a full platform and
two environments, and integrate with the cloud like production clusters.

## Considered Options

* K3s 1 server + agents · K3s 3 servers · RKE2 · Talos
* Dev/prod as namespaces · vCluster · two clusters

## Decision Outcome

* **K3s v1.37.x** (pinned; installed with the `k3s.orchestration` collection pinned by commit):
  1 server with embedded etcd and scheduled snapshots to S3, 2 workers, 1 tainted CI node.
  Three servers on two hypervisors would not survive the loss of the host holding two members.
  RKE2 (4 GB minimum) and Talos (replaces the Ansible layer) were rejected for RAM/scope.
* Hard anti-affinity pairs: {worker-1, worker-2} and {server, ci}.
* OpenStack integration: cloud-controller-manager and Cinder CSI (chart 2.37.x;
  `--disable-cloud-controller`, `cloud-provider=external`; override the OCCM nodeSelector
  because K3s labels control-plane nodes with `"true"`), LoadBalancer via Octavia OVN provider.
* Flannel VXLAN; pod MTU = tenant MTU − 50. The tenant MTU itself is **open**: 1442 (default
  on a 1500 underlay) or ≈ 8942 (`path_mtu` 9000 on `br-tun`) — see `docs/open-questions.md`.
* Dev and prod are namespaces with quotas, default-deny NetworkPolicies and separate
  CloudNativePG clusters; two clusters would double ~3.5 GB of system overhead.
* `--secrets-encryption` enabled (etcd snapshots contain every Secret).

### Consequences

* Good, because PVCs, load balancers and node lifecycle use OpenStack APIs.
* Bad, because the single K3s server is a documented single point of failure, mitigated by
  tested snapshot restores.
* Bad, because BuildKit rootless requires a privileged-PSA build namespace (guarded by Kyverno).

## More Information

[research/05-kubernetes-on-openstack.md](../research/05-kubernetes-on-openstack.md)
