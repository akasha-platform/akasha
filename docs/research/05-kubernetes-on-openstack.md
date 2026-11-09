# 05 — Kubernetes on OpenStack

Researched: 2026-11-08. RAM figures are **ESTIMATED** and must be measured with `kubectl top`, `free` and `virsh dommemstat`. Re-check all versions.

## Distribution and versions

- **K3s:** stable and latest channels are **v1.37.2+k3s1**. **VERIFIED**: https://update.k3s.io/v1-release/channels
  - 1.37 bundles the Gateway API CRDs, Traefik v3.7.13, etcd v3.7.1 and flannel 0.28.4. **VERIFIED**: https://docs.k3s.io/blog/2026/09/10/K3s-1.37-release
- **Ansible install:** `k3s-io/k3s-ansible` (`k3s.orchestration`) is maintained but has **no tags**. Pin it by commit SHA and set `k3s_version: v1.37.2+k3s1`. This replaces the old unpinned `curl | sh`. **VERIFIED**: https://github.com/k3s-io/k3s-ansible
- **Footprint:**
  - K3s server with a workload: about 1.6 GB. Agent: about 275 MB. Minimums: 2 GB for a server, 512 MB for an agent. **VERIFIED**: https://docs.k3s.io/reference/resource-profiling, https://docs.k3s.io/installation/requirements
  - RKE2 needs ≥ 4 GB (8 GB recommended), and Debian is not on its validated list. **VERIFIED**: https://docs.rke2.io/install/requirements
  - Talos v1.14.5 needs 2–4 GiB per control-plane node and replaces Ansible completely. **VERIFIED**: https://docs.siderolabs.com/talos/v1.13/getting-started/system-requirements.md

## Topology (2 hypervisors, about 10–12 GB of guest RAM)

| VM | Role | RAM (target, trimmed) | Nova server group |
|---|---|---|---|
| k3s-server-1 | server, embedded etcd (`--cluster-init`), S3 snapshots; tainted `CriticalAddonsOnly=true:NoExecute`, carries OCCM, the Cinder CSI controller and CoreDNS | 2.5 GB | B (hard anti-affinity) |
| k3s-worker-1 / k3s-worker-2 | agents for platform and apps | 3–3.5 GB each | A (hard anti-affinity) |
| k3s-ci-1 | agent tainted `ci=true:NoSchedule`, ARC runners and BuildKit only | 2–2.5 GB | B |

The server taint is documented by K3s for a dedicated control plane. **VERIFIED**: https://docs.k3s.io/datastore/ha

**Why not 3 servers.** With 2 hypervisors, one of them always holds 2 of the 3 etcd members. Losing that host loses quorum, so the HA is cosmetic. It also costs about 3 × 1.6 GB. **INFERRED**, from etcd quorum: https://etcd.io/docs/v3.5/faq/

**Single control-plane node.** One control plane with reliable, tested backup and restore is an accepted pattern. Snapshots are scheduled with `--etcd-s3*` options. **VERIFIED**: https://www.siderolabs.com/blog/scheduling-workloads-on-control-plane-nodes-in-kubernetes-a-bad-idea, https://docs.k3s.io/cli/etcd-snapshot

**Server groups.** Soft anti-affinity spreads members "as many separate hosts as possible". Hard anti-affinity accepts `max_server_per_host` from microversion 2.64. **VERIFIED**: https://docs.openstack.org/nova/latest/user/server-groups.html

## OpenStack integration ("the cloud way")

**Versions.** cloud-provider-openstack **v1.37.1**, charts **2.37.x**, tracking Kubernetes minors. **VERIFIED**: https://github.com/kubernetes/cloud-provider-openstack/releases

**K3s flags** (**VERIFIED**: https://docs.k3s.io/cli/server):
- `disable-cloud-controller: true`. It must be identical on every server.
- `kubelet-arg: ["cloud-provider=external"]`.
- `disable: [servicelb, local-storage, traefik]`. Traefik is then reinstalled through Argo CD (**INFERRED**).
- `node-ip` and `tls-san` set explicitly.

**cloud.conf.**
- Credentials: application credential (`application-credential-id`/`-secret`).
- Load balancer: `[LoadBalancer] lb-provider=ovn`, `lb-method=SOURCE_IP_PORT`, `floating-network-id`, `subnet-id`, plus `create-monitor=true` when using `externalTrafficPolicy: Local`.
- **VERIFIED**: https://github.com/kubernetes/cloud-provider-openstack/blob/master/docs/openstack-cloud-controller-manager/using-openstack-cloud-controller-manager.md

**Gotcha: OCCM node selector.** The OCCM chart's default `nodeSelector` is `node-role.kubernetes.io/control-plane: ""`. K3s labels servers `"true"`, so the pods stay Pending. Override the selector or use an `Exists` affinity. **VERIFIED** (chart values) / **INFERRED** (K3s label value): https://github.com/kubernetes/cloud-provider-openstack/issues/2550

**Cinder CSI.** Use it as the default StorageClass with `WaitForFirstConsumer`, for CloudNativePG and Prometheus PVCs. **INFERRED**

**Application credential secret.** It lands in Terraform/OpenTofu state, so the state must be encrypted (OpenTofu state encryption). **VERIFIED**: https://raw.githubusercontent.com/terraform-provider-openstack/terraform-provider-openstack/main/docs/resources/identity_application_credential_v3.md

### Load balancers: Octavia-OVN vs MetalLB

- **Octavia-OVN through OCCM** is L4 only, with no amphora VMs. One load balancer fronts Traefik, which handles TLS via cert-manager and L7 via Gateway API. **VERIFIED**: https://docs.openstack.org/ovn-octavia-provider/latest/admin/driver.html
- **MetalLB L2** needs `allowed-address-pairs` for every VIP on every port. It is a workaround, not the cloud way. **VERIFIED**: https://blog.rackspacecloud.com/blog/2024/11/05/running_metallb_on_openstack_flex/

## Networking inside OpenStack

- **Tenant MTU — OPEN decision:**
  - Default: OVN Geneve on a 1500 underlay gives **1442**. **INFERRED**: https://lists.openstack.org/archives/list/openstack-discuss@lists.openstack.org/thread/5HBDAQDUOTRNRJU5SHVC6Y54IKAJUKD7
  - Jumbo: br-tun is planned at MTU 9000 (see [04](04-host-and-network.md)); with `path_mtu` 9000 tenant networks get about **8942**. **VERIFIED/INFERRED** (see 04).
- **Pod MTU = tenant MTU − 50** (flannel VXLAN overhead): about **1392** with 1442, about **8892** with 8942. **INFERRED** (arithmetic). Flannel uses the external interface MTU unless one is set. **VERIFIED**: https://github.com/flannel-io/flannel/blob/master/Documentation/backends.md. Check `/run/flannel/subnet.env` and test with `ping -M do -s <mtu-28>`.
- **CNI choice:** keep flannel plus the embedded NetworkPolicy controller. Cilium would cost about 300–500 MiB per node. **ESTIMATED**
- **Security group `sg-k8s-nodes`** (ports **VERIFIED**: https://docs.k3s.io/installation/requirements):
  - 6443 from nodes and the bastion/Tailscale range.
  - 10250, UDP 8472 and NodePorts within the group.
  - NodePorts must also accept traffic from the Octavia-OVN load balancer source; OVN load balancers DNAT, so the client IP is preserved. **INFERRED**
  - 2379–2380 between servers only.
  - Attach it through `security_group_ids` on `openstack_networking_port_v2`.
- **API exposure:** the kube-apiserver has a private IP only. **INFERRED**

## RAM budget (realistic working set)

| Item | GiB | Tag |
|---|---|---|
| OS + K3s, 4 VMs | 3.5 | VERIFIED/ESTIMATED |
| CoreDNS, metrics-server, OCCM, Cinder CSI | 0.6 | ESTIMATED |
| Traefik, cert-manager, External Secrets | 0.45 | ESTIMATED |
| Kyverno (chart defaults: 320 Mi requests, 768 Mi limits) | 0.45 | VERIFIED: https://github.com/kyverno/kyverno/blob/main/charts/kyverno/values.yaml |
| Argo CD non-HA (dex and notifications off) | 0.75 | ESTIMATED |
| kube-prometheus-stack (5–7 d retention) | 1.4 | ESTIMATED |
| Loki SingleBinary, caches off | 0.45 | ESTIMATED |
| Alloy DaemonSet, 4 nodes | 0.5 | ESTIMATED |
| CloudNativePG operator + Barman plugin | 0.25 | ESTIMATED |
| PostgreSQL prod (2 × 512 Mi) + dev (1 × 384 Mi) | 1.4 | ESTIMATED |
| ARC controller + listener (idle) | 0.15 | ESTIMATED |
| NovaShop dev + prod | 0.5 | ESTIMATED |
| **Steady state** | **≈ 10.3** | |
| CI burst on the CI node (runner + BuildKit) | +1.5–2 | ESTIMATED |
| **Peak** | **≈ 12.3** | |

**Loki chart default.** It ships `chunksCache.allocatedMemory: 8192` MB and SimpleScalable mode, so set **SingleBinary with caches off**. **VERIFIED**: https://raw.githubusercontent.com/grafana/loki/main/production/helm/loki/values.yaml

**Conditions for the budget to hold** (**INFERRED**, from the K8s research):
- `kube-reserved` / `system-reserved` and hard eviction thresholds set on every kubelet.
- Memory requests = limits for PostgreSQL and Prometheus.
- No swap inside the K3s VMs.
- No Nova RAM overcommit for these L2 guests (`ram_allocation_ratio = 1.0`).

**Fit with layout C2.** The budget fits only after measurement and trimming (see [02](02-topology-and-nesting.md)). The choice of what to cut is **deferred until real numbers exist** (owner's decision). Cut-down options, with rough savings (**ESTIMATED**):

| Option | Saves | Cost |
|---|---|---|
| Shorter retention for metrics and logs (Prometheus 3–5 d, Loki 3 d), drop unused series | ~0.3–0.5 GB | Less history |
| A single PostgreSQL instance for prod | ~0.5 GB | No in-cluster DB replica |
| Merge the CI node into the workers (runners on a tainted worker) | ~0.8 GB | Weaker CI isolation |
| Defer or drop Octavia (NodePort instead of LoadBalancer) | ~0.3–0.5 GB on ctl01, can be given to computes | No cloud-style LoadBalancer |

**Ephemeral dev cluster (idea).** To demonstrate cluster-per-environment without paying for it permanently, CI could create a throwaway "dev" cluster from the same OpenTofu module and destroy it afterwards. **INFERRED**

### dev and prod

- **Two clusters** would double the ~3.5 GiB system overhead.
- **vCluster** costs about 0.3–0.5 GiB idle per environment. **ESTIMATED**: https://vcluster.com/docs/vcluster/deploy/control-plane/binary
- **Chosen: two namespaces**, `novashop-dev` and `novashop-prod`. Each has a ResourceQuota/LimitRange, default-deny NetworkPolicies, its own CloudNativePG cluster and its own S3 prefix. **INFERRED**

## CI runners in the cluster (public repository)

**GitHub's guidance.**
- Self-hosted runners "should almost never be used for public repositories". **VERIFIED**: https://docs.github.com/en/actions/reference/security/secure-use
- A fork PR can edit `runs-on`, so repository and org settings are the real control: require approval for external contributors, and use runner groups (org only). **VERIFIED/INFERRED**: https://docs.github.com/en/actions/how-tos/manage-runners/self-hosted-runners/manage-access

**ARC 0.15.1 configuration.**
- Controller in `arc-systems`, runners in `arc-runners`.
- `minRunners 0`, `maxRunners 1`, ephemeral runners.
- No RBAC for the runner ServiceAccount, `automountServiceAccountToken: false`.
- Default container mode (not `kubernetes` mode, which grants pod create/exec).
- Scheduled onto the tainted CI node.
- **VERIFIED**: https://docs.github.com/en/enterprise-server@3.18/actions/how-tos/manage-runners/use-actions-runner-controller/deploy-runner-scale-sets

**Workflow rule.** PR CI runs on GitHub-hosted runners. Self-hosted runners are used only on `push` to `main` and on tags.

**BuildKit rootless vs Pod Security Admission.**
- BuildKit rootless needs Unconfined seccomp and AppArmor. **VERIFIED**: https://raw.githubusercontent.com/moby/buildkit/master/examples/kubernetes/deployment%2Bservice.rootless.yaml
- PSA *baseline* forbids Unconfined seccomp. **VERIFIED**: https://kubernetes.io/docs/concepts/security/pod-security-standards/
- So the build namespace must be PSA `privileged`. Compensate with a Kyverno policy that allows only the pinned BuildKit image digest, only on the CI node, with `runAsUser: 1000`. **INFERRED**

**Egress NetworkPolicy** for runners and BuildKit: allow DNS and 443, but deny pod/service CIDRs, the node subnet (6443, 10250) and **169.254.169.254**. The metadata service may expose cloud-init user data containing the K3s join token. **INFERRED**

**Residual risk.** Industry practice is to keep CI runners in a separate cluster or VM-isolated. Here they run on a dedicated tainted node in the same cluster. That is an accepted lab trade-off, and it is documented. **INFERRED**

## Cluster API Provider OpenStack (CAPO)

- v0.15.1 (2026-10-22) on CAPI v1.14. It needs a management cluster. **VERIFIED**: https://github.com/kubernetes-sigs/cluster-api-provider-openstack/releases
- **Verdict:** it pays off with many clusters. Not for this lab; listed as a future step.
- Magnum's Heat driver was deprecated in 2025.1 in favour of CAPI drivers, which also need a management cluster. **VERIFIED**: https://docs.openstack.org/releasenotes/magnum/2025.1.html
