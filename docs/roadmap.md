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
| 5 | pre-commit hooks and lint CI on GitHub-hosted runners, one shared check list (ADR-0023) | ✅ 2026-11-10 (PR #8) |
| 6 | Renovate (Mend-hosted app, 6-day cooldown), Dependabot alerts only, explicit allow-list of actions (ADR-0024) | ✅ 2026-11-11 |
| 7 | SSH commit signing, rulesets protecting `main` (ADR-0025); drop the `admin:org` scope from the local `gh` token | ✅ 2026-11-11 |

Done when: an empty PR passes every check; actions are SHA-pinned; `main` is protected.
**P0 done on 2026-11-11.**

## P1 — L0 host (`insa`)

1. ✅ 2026-11-11 **Inventory and back up the current state.** Only `linux2024` (Proxmox) is
   left in libvirt; the two other VMs were deleted by the owner and no disk file remains.
   Inside Proxmox: OPNsense (100), DevStack (7001), DevStack template (7000), Debian template
   (105) and an old vzdump of a VM 102 (kept). The OPNsense `config.xml` (3 filter rules, near
   default) is copied to a private location outside the repository.
2. ✅ 2026-11-11 **Power off the Proxmox VM and keep it** (ADR-0005): guests and `linux2024`
   shut down cleanly, autostart disabled; host RAM available went from ~6 GiB to 28 GiB.
3. ✅ 2026-11-13 **Partition the free NVMe space and create LVM** (ADR-0009) with Ansible
   (ADR-0026): `nvme0n1p4` → `vg_akasha` → `lv_images` 320 GiB XFS on
   `/var/lib/libvirt/akasha` + `lv_cinder` 120 GiB raw, ~37 GiB free; role `host_storage`
   idempotent; activation and mount checked after a reboot. Host upgraded to Debian 13.7
   (runbook `host-upgrade.md`).
4. 🔄 Host bridges and nftables (campus LAN drop rule), Tailscale subnet routing, in three
   steps: 4a bridges + forwarding + libvirt backend, 4b nftables, 4c Tailscale.
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
