# Architecture Decision Records

Format: [MADR 4.0](https://github.com/adr/madr). One decision per file, never edited after
acceptance except to change its status (`superseded by ADR-NNNN`).

| ADR | Title | Status |
|---|---|---|
| [0001](0001-record-architecture-decisions.md) | Record architecture decisions with MADR | accepted |
| [0002](0002-github-organization-and-two-repositories.md) | GitHub organization and two repositories | accepted |
| [0003](0003-keep-openstack-as-private-cloud.md) | Keep OpenStack as the private-cloud layer | accepted |
| [0004](0004-kolla-ansible-2026-1.md) | Replace DevStack with Kolla-Ansible 2026.1 on Debian 13 | accepted |
| [0005](0005-run-vms-directly-on-libvirt.md) | Remove the Proxmox layer; run VMs directly on libvirt | accepted |
| [0006](0006-openstack-topology-v1b.md) | OpenStack topology: 1 controller + 2 computes, 3 OVN gateway chassis | accepted |
| [0007](0007-opentofu-and-providers.md) | OpenTofu with pinned libvirt and OpenStack providers | accepted |
| [0008](0008-host-networking-and-access.md) | Host networking, NAT boundary and Tailscale-only access | accepted |
| [0009](0009-host-disk-layout.md) | Host disk layout on LVM | accepted |
| [0010](0010-kubernetes-on-openstack.md) | Kubernetes: K3s on Nova with OpenStack integrations | accepted |
| [0011](0011-openbao-secrets-and-pki.md) | OpenBao for secrets, PKI and workload identity | accepted |
| [0012](0012-object-storage-and-backups.md) | Object storage and backups | accepted |
| [0013](0013-ci-cd-security-model.md) | CI/CD security model for a public repository | accepted |
| [0014](0014-gitops-with-argo-cd.md) | GitOps with Argo CD and a separate gitops repository | accepted |
| [0015](0015-observability-stack.md) | Observability stack | accepted |
| [0016](0016-host-memory-headroom.md) | Host memory headroom techniques | proposed |
| [0017](0017-ingress-traefik-gateway-api.md) | Ingress: Traefik with Gateway API behind an Octavia L4 load balancer | accepted |
| [0018](0018-postgresql-cloudnativepg.md) | PostgreSQL with CloudNativePG | accepted |
| [0019](0019-certificate-management.md) | Certificate management: OpenBao PKI, cert-manager, trust-manager | accepted |
| [0020](0020-policy-engine-kyverno.md) | Policy engine: Kyverno with Pod Security Admission | accepted |
| [0021](0021-repository-layout.md) | Repository layout | accepted |
| [0022](0022-pinned-toolchain.md) | Pinned and verified developer toolchain (mise + uv) | accepted |
| [0023](0023-local-hooks-and-lint-ci.md) | Local git hooks and lint CI share one check list | accepted |
