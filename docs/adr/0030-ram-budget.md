---
status: accepted
date: 2026-11-17
decision-makers: dhuy21
---

# RAM budget: at least 3 GiB of the host stays free, by plan

## Context and Problem Statement

The design committed about 100% of the host's memory. On 2026-11-16 the owner required that
at least 3 GB stay free; ADR-0028 replaced the 3 GB OPNsense with a 0.5 GiB router. How much
RAM does each VM get so that the requirement holds?

Measured on `insa` (read-only, no VM running, the school's GNOME session logged in on seat0):

| | 2026-11-16 | 2026-11-17 |
|---|---|---|
| MemTotal | 31 839 MiB | 31 839 MiB (32 603 368 kB) = **31.09 GiB** |
| Used by the host (`free`: total − available) | 1 784 MiB | 1 773 MiB |
| Swap | 25 182 MiB, unused | same |
| Static huge pages | | 0 |

## Decision Drivers

* The owner's definition (2026-11-17): **3 GiB**, counted **by plan**: VM allocations plus the
  host's own use ≤ MemTotal − 3 GiB. KSM, free page reporting and zswap are not counted
  (ADR-0016). The 3 GiB also absorbs what the school's desktop may use on top of the idle
  baseline (a browser session, updates, `/tmp`, which Debian 13 mounts as tmpfs of up to 50%
  of RAM), since akasha cannot limit it (ADR-0027).
* The controller and the computes are already at the edge of what Kolla 2026.1 and the K3s
  layout need (below).

## Considered Options

The draft (VMs 25.45 GiB, host 3 GiB) left 2.64 GiB free, 0.36 GiB short. An independent
review on 2026-11-17 checked these ways to close the gap:

* **Shrink the computes (7.6 → 7.4 GiB each). Rejected.** Nova schedules on the guest's
  MemTotal minus `reserved_host_memory_mb` and adds no per-instance overhead (VERIFIED: nova
  `virt/libvirt/host.py` `get_memory_mb_total`). A 7.6 GiB compute keeps about 4.95–5.8 GiB
  for instances after the OS, the Nova/OVN agents and the reserve (1 800–2 600 MiB in
  research 02/03); the compute carrying the K3s server and a worker needs 5.5–6 GiB. 7.6 GiB
  is already marginal; 7.4 GiB does not fit.
* **Shrink the controller (8 → 7.6 GiB).** Risky: research 02 recorded a 2026.1 all-in-one at
  about 12.3 GB and Kolla CI OOM kills on 8 GB nodes. Kolla's defaults are larger than the
  tuned plan: Galera's buffer pool is 40% of MemTotal capped at 8 GiB and
  `openstack_service_workers` is `min(vCPUs, 5)` (VERIFIED: kolla-ansible `stable/2026.1`
  `roles/mariadb/templates/galera.cnf.j2:56-60`, `group_vars/all/common.yml:327-328`), so the
  overrides of research 03 (512M buffer pool, one worker, RabbitMQ absolute limit) are needed
  even at 8 GiB.
* **Keep the sizes and decide after measuring.** Leaves the plan below the requirement.
* **Shrink the bastion and core, headless VMs, and a measurement gate in step 6.**

## Decision Outcome

Chosen option: **"Shrink the bastion and core, headless VMs, measurement gate"**, chosen by
the owner on 2026-11-17.

| VM | RAM (MiB) | GiB | Note |
|---|---|---|---|
| router | 512 | 0.5 | Debian minimum (ADR-0028); not lower |
| bastion | 768 | 0.75 | was 1 GiB; 1 GiB swap file inside the guest, Ansible `forks` ≤ 5; a failed deploy is rerun |
| core | 614 | 0.6 | was 0.75 GiB; if OpenBao is OOM-killed it restarts sealed |
| os-ctl01 | 8 192 | 8 | unchanged; Kolla overrides of research 03 required |
| os-cmp01 | 7 782 | 7.6 | unchanged |
| os-cmp02 | 7 782 | 7.6 | unchanged |
| **VMs** | **25 650** | **25.05** | |
| Host's own use, planned | 3 072 | 3 | measured 1.73 + QEMU/libvirt overhead (KubeVirt's formula: ≈ 0.65 GiB, up to ≈ 1.3 GiB with dedicated CPUs) + nested-paging and exporters (≈ 0.1–0.35); range 2.4–3.4 GiB (ESTIMATED) |
| **Free** | **3 117** | **3.04** | thin |

* Sizes are written in MiB in OpenTofu (libvirt takes integers), never as "GB".
* **Headless VMs:** no graphics or video device, no sound, no USB controller; access by SSH
  and by the serial console (`ttyS0`, `virsh console`). About 32 MiB of host memory per VM
  (KubeVirt's formula), owned by akasha.
* **Gate in step 6:** with every L0 VM running, the host's measured share (its own processes
  plus each VM's QEMU overhead) plus the full VM allocations must leave at least 3 GiB of
  MemTotal; an idle VM does not touch all its RAM, so `MemAvailable` alone would look too
  good. The measurement method is part of the step-6 plan. If the gate fails, step 6 stops
  and the owner chooses a further cut before OpenStack is deployed. The same check is
  repeated after the Kolla deploy (open question A2).
* **If the controller needs more than 8 GiB** (A2), the RAM comes from the K3s guests (fewer
  or smaller components, open question B1 cuts), not from the free margin.
* **`linux2024`** (24 GiB) stays powered off while the lab runs (owner's decision of
  2026-11-11); starting it would overcommit the host about twice.
* No static huge pages (they cannot be shared by KSM). The host's 25 GiB swap remains a slow
  buffer; PSI and swap-in alerts (ADR-0016) are the signal, set up in step 5.
* OOM order: `systemd-oomd` is not installed on `insa` (checked 2026-11-17: unit not found),
  so only the kernel's OOM killer acts, and it would pick the largest process, the
  controller's QEMU. Per-VM `oom_score_adj` and `MemoryLow=` (ADR-0016) are set in step 5,
  order decided there.

### Consequences

* Good, because the plan meets the owner's 3 GiB and every number is written down with its
  source or tag.
* Good, because the gate turns the estimates into a measurement before anything is built on
  top of the VMs.
* Bad, because the margin is thin (about 0.04 GiB above the requirement on paper) and the
  host's share is an estimate; the gate may force further cuts, which would fall on K3s.
* Bad, because the bastion relies on guest swap during large Ansible runs (slower deploys),
  and core has little room above OpenBao and versitygw.

### Confirmation

The step-6 gate and the post-deploy check (A2); per-VM RSS with `virsh dommemstat` and the
host's `MemAvailable` over a working day (school desktop in use).

## More Information

Independent review of 2026-11-17 (draft and findings in the project's working notes);
[research/02](../research/02-topology-and-nesting.md),
[research/03](../research/03-kolla-2026.1-findings.md),
[research/05](../research/05-kubernetes-on-openstack.md),
[research/08](../research/08-observability-and-host-memory.md), ADR-0016.

## Updates

* 2026-11-22: every VM gets a VGA adapter, still without any display
  ([ADR-0034](0034-vga-adapter-on-lab-vms.md)): Debian's cloud images do not boot without a
  video device. "No graphics or video device" above becomes "no graphics device"; the
  adapter's memory is measured at the step-6 gate.
