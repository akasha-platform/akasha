# Roadmap

Work proceeds **one étape at a time**; each étape is planned, approved, executed,
verified and validated before the next one starts.

Legend: ✅ done · 🔄 in progress · ⏳ planned

## P0 — Repository foundations (laptop + GitHub only)

| Étape | Scope | Status |
|---|---|---|
| 1 | GitHub org `akasha-platform`, transfer `akasha`, create `akasha-gitops`, org Actions policy (SHA pinning, read-only token, fork-PR approval), org 2FA with secure methods only | ✅ 2026-11-08 |
| 2 | Durable record of all decisions: `CLAUDE.md`, roadmap, architecture overview, ADRs, research notes | 🔄 |
| 3 | Tag the TD2 baseline (`td2-final`), remove it from the tree, create the new directory skeleton, README/LICENSE/SECURITY.md | ⏳ |
| 4 | Pinned local toolchain (OpenTofu, pre-commit, tflint, ansible-lint, …) | ⏳ |
| 5 | pre-commit configuration and lint CI on GitHub-hosted runners | ⏳ |
| 6 | Renovate, zizmor, restrict allowed actions to a selected list | ⏳ |
| 7 | SSH commit signing, rulesets protecting `main` | ⏳ |

## P1 — L0 host (`insa`)

Inventory and back up the current state → remove the Proxmox VM → partition
the free NVMe space and create LVM → host bridges and nftables → Tailscale
subnet routing → memory headroom (KSM, zswap, free page reporting) and host
monitoring → OpenTofu L0: base image, OPNsense, bastion, core (OpenBao + versitygw).

## P2 — L1 OpenStack (Kolla-Ansible 2026.1)

Kolla configuration as code, OpenBao-backed passwords and TLS, deploy 1 controller
+ 2 computes (3 OVN gateway chassis), power-loss test of single-node Galera,
backups, measurement of real memory overhead.

## P3 — L2 OpenStack resources

Domains/projects/users/application credentials, quotas, networks, images,
flavors — all with OpenTofu.

## P4 — L3 Kubernetes

K3s (1 server + 2 workers + 1 CI node) on Nova with anti-affinity, OCCM,
Cinder CSI, Octavia-OVN load balancer.

## P5 — L4 platform

Argo CD (app-of-apps / ApplicationSets from `akasha-gitops`), Traefik + Gateway
API, cert-manager (OpenBao issuer), External Secrets, Kyverno, CloudNativePG,
kube-prometheus-stack, Loki, Alloy, ARC runners.

## P6 — L5 application

NovaShop rebuilt as container images, CI (lint, test, build, scan, sign,
attest), GitOps promotion dev → prod.

## P7 — Operations

SLOs and alerts, runbooks, backups and restore drills (off-site AWS S3),
failure drills (live migration, evacuation), postmortems, optional `net01`.
