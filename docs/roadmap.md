# Roadmap

Work proceeds **one étape at a time**; each étape is planned, approved, executed,
verified and validated before the next one starts. Open items and pending tests are
tracked in [open-questions.md](open-questions.md).

Legend: ✅ done · 🔄 in progress · ⏳ planned

## Definition of Done (every étape / phase)

- Change merged through a reviewed pull request (squash merge).
- ADR added or superseded when the design changes; architecture overview and README updated.
- Runbook written for every new failure mode; verification steps recorded.
- No secret or sensitive address committed (see `CLAUDE.md`).

Phase-specific completion criteria are listed with each phase below.

## P0 — Repository foundations (laptop + GitHub only)

| Étape | Scope | Status |
|---|---|---|
| 1 | GitHub org `akasha-platform`, transfer `akasha`, create `akasha-gitops`, org Actions policy (SHA pinning, read-only token, fork-PR approval), org 2FA with secure methods only | ✅ 2026-11-08 |
| 2 | Durable record of all decisions: `CLAUDE.md`, roadmap, architecture overview, ADRs, research notes; audit against the design conversation (PR #1, PR #2) | ✅ 2026-11-09 |
| 3 | Tag the TD2 baseline (`td2-final`), remove it from the tree, new directory skeleton (`infra/opentofu/`, ADR-0021), README, Apache-2.0 LICENSE, SECURITY.md, `.gitignore`; repository security settings (secret scanning, push protection, squash-only) | ✅ 2026-11-09 |
| 4 | Pinned and verified local toolchain: mise + `mise.lock`, uv + `uv.lock` (ADR-0022, `docs/development.md`) | ✅ 2026-11-09 |
| 5 | pre-commit configuration and lint CI on GitHub-hosted runners | ⏳ |
| 6 | Renovate, zizmor, restrict allowed actions to a selected list | ⏳ |
| 7 | SSH commit signing, rulesets protecting `main`; drop the `admin:org` scope from the local `gh` token | ⏳ |

Done when: an empty PR passes every check; actions are SHA-pinned; `main` is protected.

## P1 — L0 host (`insa`)

1. **Inventory and back up the current state.** The Proxmox VM contains: OPNsense (VMID 100),
   DevStack (7001), the DevStack template (7000) and a Debian VM (105). Confirm with the owner
   that nothing must be kept before deletion.
2. Remove the Proxmox VM.
3. Partition the free NVMe space and create LVM (`vg_akasha`, see ADR-0009).
4. Host bridges and nftables (campus LAN drop rule), Tailscale subnet routing.
5. Memory headroom (KSM, zswap, free page reporting) and host monitoring (ADR-0016).
6. OpenTofu L0 (first apply from the laptop; state location decided before this step;
   OpenTofu bumped to ≥ 1.13.9 first, see ADR-0022):
   base image, OPNsense, bastion, core (OpenBao + versitygw).
7. OpenBao initialisation (Shamir; self-init test A14), in-lab S3 conditional-write test (A3),
   restic to AWS S3 with Object Lock (design + test A13), host checks (A15).

Done when: the L0 stack rebuilds from zero, lab traffic cannot reach the campus LAN, the
laptop reaches the lab only through Tailscale.

## P2 — L1 OpenStack (Kolla-Ansible 2026.1)

Kolla configuration as code (pinned kolla-ansible), passwords from OpenBao KV v2
(`kolla-readpwd` acceptance test), TLS from the OpenBao PKI, deploy 1 controller + 2 computes
(3 OVN gateway chassis), **measure real memory overhead**, cold-boot test of single-node Galera
(`virsh destroy`), backups (`mariadb-backup`), boot-order unit and post-boot health check.

Done when: `openstack` CLI smoke tests pass, cold boot recovers by the runbook, measured
`reserved_host_memory_mb` is set.

## P3 — L2 OpenStack resources

Domains, projects, users, application credentials, quotas, networks, images, flavors — all
with OpenTofu (OpenTofu `openbao` key-provider acceptance test).

## P4 — L3 Kubernetes

K3s (1 server + 2 workers + 1 CI node) on Nova with anti-affinity, OCCM, Cinder CSI,
Octavia-OVN load balancer, etcd snapshots to S3 with a tested restore.

## P5 — L4 platform

Argo CD bootstrapped once, then ApplicationSets from `akasha-gitops`; Traefik + Gateway API,
cert-manager (OpenBao issuer acceptance test) + trust-manager, External Secrets (OpenBao
acceptance test), Kyverno, CloudNativePG, kube-prometheus-stack, Loki, Alloy, ARC runners.

Done when: recreating the cluster converges the platform with no manual step.

## P6 — L5 application

NovaShop rebuilt as container images (fixing the TD2 defects listed in
[research/00](research/00-td2-baseline-assessment.md)), CI (lint, test, build, scan, SBOM,
sign, attest), GitOps promotion dev → prod.

## P7 — Operations

SLOs and alerts, runbooks, backup and restore drills (off-site AWS S3), failure drills (live
migration, evacuation, CI-node preemption), postmortems, KSM A/B measurement, optional `net01`.
