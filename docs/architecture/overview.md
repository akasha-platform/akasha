# Architecture overview

Status: target design, decided 2026-11-08 (see [ADRs](../adr/README.md)).
Numbers marked *est.* are estimates to be replaced by measurements.

## 1. Constraints

- **One physical host** (school-provided): Intel i7-14700 (8 P-cores with HT + 12 E-cores = 28 threads),
  31 GiB usable RAM, 954 GB NVMe (477 GiB unallocated), Debian 13. No extra hardware is possible.
- The host also has a campus network uplink; lab traffic must never enter the campus LAN.
- Remote access only through Tailscale.
- The repository is public.

Consequence: every "multi-node" property below is simulated on one failure domain.
The design reproduces production **mechanisms** (role separation, overlay networks,
anti-affinity, GitOps, PKI, backups) and documents where it cannot reproduce
production **guarantees** (HA control planes, Ceph, N+2 capacity).

## 2. Layers

```
L5 App        NovaShop (frontend, API, PostgreSQL) — namespaces dev / prod
L4 Platform   Argo CD · Traefik + Gateway API · cert-manager · External Secrets · Kyverno
              CloudNativePG · kube-prometheus-stack · Loki · Alloy · ARC runners
L3 K8s        K3s: 1 server + 2 workers + 1 CI node, on Nova VMs
L2 Resources  OpenStack projects, users, app credentials, networks, images, flavors (OpenTofu)
L1 OpenStack  Kolla-Ansible 2026.1 · 1 controller + 2 computes · ML2/OVN · Octavia (OVN provider)
L0 Host       libvirt/KVM VMs (OpenTofu) · Linux bridges · nftables · OPNsense · bastion · core
```

## 3. L0 — host and VMs

All VMs are libvirt guests created by OpenTofu (`dmacvicar/libvirt` 0.9.9). There is no
Proxmox layer, so Kubernetes VMs run at nesting level 2 ([ADR-0005](../adr/0005-run-vms-directly-on-libvirt.md)).

| VM | Role | vCPU (pinned) | RAM | Disk |
|---|---|---|---|---|
| opnsense | Edge router/firewall, DNS (Unbound), NTP | 2 → E-cores | 3 GB | 16 G |
| bastion | Runs OpenTofu/Ansible/Kolla; single SSH entry point for CI (via Tailscale) | 1 → E-cores | 1 GB | 20 G |
| core | OpenBao (secrets, PKI, SSH CA, JWT auth) + versitygw (in-lab S3) | 1 → E-cores | 0.75 GB | 20 G + data |
| os-ctl01 | OpenStack control plane, API VIP (HAProxy/keepalived), Cinder LVM, OVN gateway | 4 → P-cores | 8 GB | 60 G + 120 G raw LV |
| os-cmp01 | Nova compute + OVN gateway chassis (AZ a) | 6 → P-cores | ~7.6 GB | 100 G |
| os-cmp02 | Nova compute + OVN gateway chassis (AZ b) | 6 → P-cores | ~7.6 GB | 100 G |
| host | Debian, libvirt, QEMU overhead of 6 VMs, Tailscale | E-cores | ~3 GB | — |

**RAM is ~100% committed** (≈31 GB). Headroom techniques (KSM, free page reporting,
zswap) are a safety buffer, not capacity ([ADR-0016](../adr/0016-host-memory-headroom.md)).

### Networks (Linux bridges on the host)

| Bridge | CIDR | MTU | Purpose |
|---|---|---|---|
| br-transit | 10.255.255.0/29 | 1500 | Host ↔ OPNsense WAN. The host is the only NAT to the uplink and drops lab → campus LAN |
| br-mgmt | 10.10.0.0/24 | 1500 | Management + OpenStack APIs, internal VIP .100, external VIP .101 |
| br-tun | 10.30.0.0/24 | 9000 | Geneve overlay between controller and computes |
| br-ext | 10.20.0.0/24 | 1500 | Provider/floating-IP network (FIP pool .100–.250), unaddressed NICs on ctl + computes |

DNS zone: `akasha.internal`. Access from the operator laptop: Tailscale subnet router on the host.

### Disk

```
NVMe free space (477 GiB) → LVM VG vg_akasha
├─ lv_images 320 GiB  XFS → libvirt dir pool "akasha" (thin qcow2)
├─ lv_cinder 120 GiB  raw → attached to os-ctl01 → guest VG "cinder-volumes"
└─ ~37 GiB free for LVM snapshots / growth
```

## 4. L1 — OpenStack

Kolla-Ansible 2026.1 "Gazpacho" (SLURP), Debian 13 hosts, ML2/OVN with distributed
floating IPs, three OVN gateway chassis (controller + both computes), Cinder LVM,
Octavia with the OVN provider (L4 only), Secure RBAC defaults. Low-RAM tuning:
one worker per API, no Heat, no fluentd, Galera buffer pool 512 MB, RabbitMQ
absolute memory watermark, `reserved_host_memory_mb` set from measurements.
Passwords and TLS material come from OpenBao. Details: [ADR-0004](../adr/0004-kolla-ansible-2026-1.md),
[ADR-0006](../adr/0006-openstack-topology-v1b.md), [research note](../research/03-kolla-2026.1-findings.md).

## 5. L3/L4 — Kubernetes and platform

| VM (Nova) | Role | RAM *est.* | Anti-affinity group |
|---|---|---|---|
| k3s-server-1 | K3s server, embedded etcd, snapshots to S3 | 2.5 GB | B |
| k3s-worker-1/2 | Workloads | 3–3.5 GB each | A |
| k3s-ci-1 | Tainted node for ARC runners and BuildKit | 2 GB | B |

Total guest RAM available ≈ 10–12 GB *est.*; platform working set ≈ 10.3 GB steady,
≈ 12.3 GB during image builds *est.* Cut-downs are decided after measurement.

## 6. Delivery and trust

- Infra changes: GitHub-hosted runner joins Tailscale with an ephemeral identity and
  reaches only the bastion; plan on PR, apply after merge with environment approval.
- App changes: build on ARC (push/tag only), sign with cosign, attest, push to GHCR,
  open a PR in `akasha-gitops`; Argo CD syncs.
- Secrets: OpenBao (Shamir unseal by hand after each host reboot). Root CA offline.
- Backups: restic to in-lab S3 (versitygw) and off-site AWS S3 with Object Lock.

## 7. Production north star (not built here)

What a real deployment of the same platform would use, and why the lab differs:

| Production | Lab | Reason |
|---|---|---|
| 3+ controllers (Galera/RabbitMQ/OVN quorum) | 1 controller | RAM; quorum on one host would be cosmetic |
| Dedicated network nodes / BGP | Gateways on ctl + computes; `net01` optional later | RAM |
| Ceph (≥3–5 nodes) | Cinder LVM on one node | RAM, single disk |
| N+1/N+2 compute capacity | 2 computes, CI node as preemptible spare | RAM |
| 3 K8s control-plane nodes in 3 zones | 1 K3s server + etcd snapshots | Only 2 hypervisors |
| HA Vault/OpenBao with auto-unseal (KMS/HSM) | 1 OpenBao node, Shamir | No KMS/HSM |
