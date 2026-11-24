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
4. ✅ 2026-11-17 Host bridges and nftables (campus LAN drop rule), Tailscale subnet routing,
   in four steps: 4a bridges + forwarding + libvirt backend, 4b nftables, 4c Tailscale, 4d
   lab-range drop rule.
   * 4a ✅ 2026-11-14: role `host_network` (ADR-0008): `br-transit`, `br-mgmt`, `br-tun`
     (MTU 9000), `br-ext` owned by ifupdown and unmanaged by NetworkManager, IPv4 forwarding,
     libvirt nftables backend, `default` network stopped; idempotent.
   * 4b ✅ 2026-11-16: role `host_firewall` (ADR-0008, ADR-0027): table `inet akasha` scoped to
     the lab bridges, lab → public Internet only (private ranges and the campus's public prefix
     blocked), NAT on the uplink, only `br-transit` routes; host traffic unchanged; checked with
     fake lab VMs.
   * 4c ✅ 2026-11-17: `insa` advertises 10.10.0.0/24 and 10.20.0.0/24 (approved by hand, SNAT
     on); the tailnet policy lets only the owner's laptop reach them, the owner's devices still
     reach each other; checked with a fake lab router (runbook `host-tailscale.md`).
   * 4d ✅ 2026-11-17 (follow-up of the 4c review): role `host_firewall` drops routed packets to
     a lab range that would leave through any interface other than `br-transit` (e.g. tailnet
     packets to the lab when the `br-transit` routes are missing would otherwise reach the
     campus network); checked with a dummy interface, regressions of 4b and 4c pass.
5. Memory headroom and host monitoring (ADR-0016), reordered by the owner on 2026-11-17:
   * 5a ✅ 2026-11-17: read-only host checks (kernel features, KSM and zswap off, swappiness
     60, swap unused, memory pressure near zero, `machine.slice` without limits, libvirtd
     socket-activated, no hook, no exporter).
   * The akasha-only parts (free page reporting, headless VMs, a `machine-akasha.slice` for the
     lab's VMs) are built in step 6.
   * The host-wide parts (KSM, zswap, swappiness, OOM order, `MemoryLow=`) are decided one by
     one after the step-6 RAM gate, from measurements.
   * Host monitoring (node-exporter) waits until a Prometheus exists (P5); until then
     measurements are read-only commands over SSH.
6. 🔄 OpenTofu L0 (applied from the laptop; state in a dedicated AWS S3 bucket, ADR-0031),
   in four steps:
   * 6a ✅ 2026-11-20: stack skeleton `infra/opentofu/live/l0-host` (OpenTofu 1.13.9, provider
     libvirt 0.9.9 with hashes checked against its signed release), partial S3 backend, state
     and plans encrypted (pbkdf2 chained to the passphrase in GNOME Keyring); empty apply,
     encrypted object checked in S3, lock checked, off-AWS copy (runbook `opentofu-l0.md`).
   * 6b: VM module (headless, sizes in MiB, free page reporting, cloud-init without secrets,
     `ignore_changes` of open question A23), Debian 13 base image, the edge router VM and its
     Ansible role (ADR-0028, ADR-0029):
     * 6b-1 ✅ 2026-11-22: module `libvirt-vm`, pool `akasha`, checked Debian 13 base image and
       the router VM (ADR-0033, ADR-0034); boots, reachable by SSH through the tailnet, host
       key checked against the serial console, forwarding off, second plan empty, A23 drill
       passed.
     * 6b-2 ✅ 2026-11-22: Ansible reaches the lab VMs by their `br-mgmt` address without `-K`;
       role `vm_base` (image defaults checked, console-only password, SSH keys only and no
       root) applied to the router, second run `changed=0`, console login checked (ADR-0035).
     * 6b-3a ✅ 2026-11-23: the router's DNS (role `router_dns`: Unbound on the lab
       addresses only, zone `akasha.internal` with reverse records, forwarding to Google and
       Cloudflare, DNSSEC validated locally) and time (role `router_time`: chrony over NTP in
       place of timesyncd, serving the lab ranges, ADR-0036); every check passed, second run
       `changed=0`, router 0.8 ms from NTP time, +14 MiB used.
     * 6b-3b ✅ 2026-11-23: role `router_firewall` (ADR-0037).
       * nftables with default drop, loaded commit confirmed; forwarding on only through a unit
         that requires the firewall.
       * Independent review: 2 blockers fixed before running.
       * Second run `changed=0`.
       * Fake clients on `br-mgmt` and `br-ext`: 14/14 cases as expected, spoofed source
         dropped, drops logged.
     * 6b-4 ✅ 2026-11-24: reboot test, memory measurement and rebuild of the router.
       * **Boot order.** Rules were in place about 3 s before networkd, and forwarding came on
         after them. A boot with a broken firewall file left forwarding off, and the role
         recovered it.
       * **Memory.** The guest used 102 MiB of 464 MiB. The host keeps about 532 MiB for it,
         because free page reporting returns nothing (A24).
       * **Rebuild from zero.** Through the runbook, after an independent review: the new
         router is byte-identical to the old one, except its kernel.
   * 6c: bastion and core, split by the owner on 2026-11-24:
     * 6c-1 ✅ 2026-11-24: the two VMs and their common base: OpenTofu, with core's data disk
       outliving the VM (ADR-0038); Ansible roles `lab_client` (router as gateway, DNS and
       only time source, ptp_kvm read by the checks only), `vm_data_disk`, `vm_swap`.
       * Independent review: 2 blockers and 4 should-fix findings fixed before running.
       * Both playbooks passed every check, and second runs reported `changed=0`.
       * The rebuild of `core` kept its data disk: same marker, UUID and creation time.
     * 6c-2: core: OpenBao 2.7.3 (pinned package, Raft on `/srv`, localhost only,
       uninitialised, ADR-0039) and a host firewall (role `vm_firewall`, through the shared
       commit-confirmed role `nft_commit`). versitygw is deferred until OpenBao can serve it a
       certificate and P4 needs it.
     * 6c-3: bastion: toolchain (mise, uv, OpenTofu, Ansible, kolla-ansible).
   * 6d: OpenStack controller and computes, then the RAM gate (ADR-0030).
7. OpenBao initialisation (Shamir; self-init test A14),
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
