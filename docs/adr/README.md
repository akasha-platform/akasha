# Architecture Decision Records

Format: [MADR 4.0](https://github.com/adr/madr). One decision per file. After acceptance the
decision itself is never rewritten: a change of decision is a new ADR, and the old one gets
its status changed or a dated note pointing to the new one. Only dated sections may be added:
`Implementation (<date>)`, `Confirmation`, and an `Updates` list (owner's rule of 2026-11-18).

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
| [0024](0024-dependency-updates-and-allowed-actions.md) | Dependency updates with Renovate and an allow-list of GitHub Actions | accepted |
| [0025](0025-signed-commits-and-rulesets.md) | Signed commits and repository rulesets protecting `main` | accepted |
| [0026](0026-ansible-conventions.md) | Ansible conventions for host configuration | accepted |
| [0027](0027-guest-on-the-school-host.md) | akasha is a guest on the school host: minimal footprint and reviewed host changes | accepted |
| [0028](0028-lab-edge-router-debian.md) | Lab edge router: a minimal Debian 13 VM instead of OPNsense | accepted |
| [0029](0029-lab-time-source.md) | Lab time source: the edge router keeps UTC over HTTPS and serves NTP to the lab | accepted (router part replaced by 0036) |
| [0030](0030-ram-budget.md) | RAM budget: at least 3 GiB of the host stays free, by plan | accepted |
| [0031](0031-l0-state-in-aws-s3.md) | L0 OpenTofu state in a dedicated AWS S3 bucket | accepted |
| [0032](0032-ci-states-in-aws-s3.md) | CI-applied OpenTofu states in AWS S3, applied from the bastion | accepted |
| [0033](0033-lab-vm-conventions.md) | Conventions for the lab's VMs on `insa` | accepted |
| [0034](0034-vga-adapter-on-lab-vms.md) | A VGA adapter on every lab VM, still without a display | accepted |
| [0035](0035-access-to-the-lab-vms.md) | Access to the lab's VMs: SSH keys, a console password and passwordless sudo | accepted |
| [0036](0036-router-time-over-ntp.md) | The edge router follows UTC over NTP with chrony and serves it to the lab | accepted |
| [0037](0037-router-firewall-and-forwarding.md) | Firewall and forwarding of the edge router | accepted |
| [0038](0038-data-disks-outlive-vms.md) | Data disks of the lab's VMs outlive the VMs | accepted |
| [0039](0039-openbao-on-core-bootstrap.md) | OpenBao on core: pinned package, localhost until its initialisation, and a host firewall | accepted |
| [0040](0040-bastion-toolchain.md) | Toolchain of the bastion: pinned mise, the repository at one commit, an unprivileged user | accepted |
| [0041](0041-openstack-node-vms.md) | OpenStack node VMs: dedicated sibling P-cores, three NICs, a raw LV for Cinder | accepted |
| [0042](0042-updates-of-pinned-release-binaries.md) | Updates of the release binaries pinned in Ansible roles | accepted |
| [0043](0043-oom-order-of-the-lab-vms.md) | OOM order of the lab VMs on the school's host | accepted |
| [0044](0044-offline-root-ca.md) | The lab's offline root CA | accepted |
| [0045](0045-openbao-initialisation-and-administration.md) | OpenBao: initialisation, unseal shares, audit log and administrator | accepted |
| [0046](0046-openbao-pki-intermediate.md) | OpenBao's intermediate CA, configured with OpenTofu | accepted |
| [0047](0047-openbao-tls-and-network-access.md) | OpenBao's TLS listener, its certificate and who may reach it | accepted |
| [0048](0048-off-site-backups-restic-s3-object-lock.md) | Off-site backups: restic to AWS S3 with Object Lock in compliance mode | accepted |
| [0049](0049-openbao-daily-backup.md) | OpenBao's daily off-site backup from core | accepted |
| [0050](0050-bastion-ssh-certificates-from-openbao.md) | SSH from the bastion to the OpenStack nodes with short-lived certificates from OpenBao | accepted |
| [0051](0051-kolla-toolchain.md) | Kolla-Ansible's toolchain: a stable/2026.1 commit, the repository's Python, its own collections | accepted |
