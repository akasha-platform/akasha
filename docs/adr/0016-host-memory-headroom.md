---
status: proposed
date: 2026-11-08
decision-makers: dhuy21
---

# Host memory headroom techniques

## Context and Problem Statement

The design commits ~100% of the host's 31 GB, whereas production capacity plans keep explicit
headroom (N+1/N+2; a 20–30% margin is a common rule of thumb — ESTIMATED, not sourced). How can
safety margin be created without buying RAM, without destabilising Galera, RabbitMQ or etcd?

## Decision Outcome (proposed, confirmed after measurement)

* KSM on the host only, with the kernel 6.x advisor (`advisor_mode=scan-time`,
  `use_zero_pages=1`); optionally `nosharepages` for `os-ctl01`. Expected 1.5–4 GB.
  Side-channel risk accepted (single tenant).
* virtio-balloon free page reporting on Linux VMs except `os-ctl01` (OPNsense/FreeBSD does
  not support it). Expected 0.5–3 GB.
* zswap (zstd, zsmalloc, 20% pool) in front of the NVMe swap, `vm.swappiness` ≈ 80;
  zram rejected (LRU inversion with disk swap).
* Host monitoring: node-exporter (+ ksmd collector), PSI and OOM alerts, per-VM memory.
  No systemd-oomd/earlyoom on VMs; `MemoryLow=` on `machine.slice` and per-VM
  `oom_score_adj` so the least important VM is sacrificed first.

Headroom is never counted as capacity: VMs are sized as if KSM were off.

### Scope on the school's host and order (2026-11-17)

Research of 2026-11-17 against kernel 6.12, libvirt 11.3.0, QEMU 10.0 and systemd 257 sources
(ADR-0027 asks what each technique touches):

* **KSM:** the knobs (`/sys/kernel/mm/ksm/*`) are host-wide, but only memory marked mergeable
  is scanned: QEMU marks guest RAM mergeable by default (`mem-merge`), libvirt's
  `<nosharepages/>` turns it off per domain, and other processes are not scanned unless they
  opt in. VERIFIED: https://docs.kernel.org/admin-guide/mm/ksm.html. The school's desktop is
  not merged; ksmd's CPU is spent on the host. Runtime setting, no reboot.
* **zswap and `vm.swappiness`:** host-wide by nature (they change how the school's desktop
  swaps). zswap can be enabled at runtime without touching GRUB or the initramfs: `zsmalloc`
  is built into the Debian kernel (`CONFIG_ZSMALLOC=y`) and `zstd` is loaded on demand.
  Per-cgroup controls (`memory.zswap.max`, `memory.swap.max`) exist.
* **Free page reporting:** per domain, no host-wide effect. Since ADR-0028 the router is
  Debian, so every VM supports it (the OPNsense/FreeBSD exception above no longer applies).
* **`MemoryLow=`:** only works if every ancestor is protected too, so it needs a drop-in on
  `machine.slice`, shared with the owner's `linux2024`; it moves reclaim onto the school's
  desktop. The kernel's global OOM killer ignores `memory.low`.
* **`oom_score_adj`:** libvirt never sets it and `libvirtd.service` has `OOMScoreAdjust=0`, so
  QEMU inherits 0. Setting it needs a libvirt hook (runs for every domain, needs a libvirtd
  restart) or an `akasha-*` timer; only positive values on akasha's VMs keep the school's
  processes out of it.
* **node-exporter:** Debian's `prometheus-node-exporter` 1.9.0 listens on `:9100` on every
  interface and starts at install, so its listen address must be set before the first start
  (ADR-0027: nothing listens on the uplink).

Host state on 2026-11-17 (step 5a, read-only): kernel 6.12.116 with `ZSWAP=y`, `ZSMALLOC=y`,
`KSM=y`, `PAGE_REPORTING=y`, `VIRTIO_BALLOON=m`, `CRYPTO_ZSTD=m`; zswap off (`lzo`,
`zsmalloc`, 20%); KSM off (`advisor_mode` none, `smart_scan` 1); `vm.swappiness` 60; 24.6 GiB
swap partition unused; memory pressure (PSI) near zero; cgroup2 with `memory_recursiveprot`;
`machine.slice` without limits; libvirt 11.3.0, socket-activated; no libvirt hook; no
`ksmtuned`, no Prometheus package; `/tmp` is tmpfs of up to 15.5 GiB.

Order chosen by the owner on 2026-11-17:

1. The akasha-only parts (free page reporting, headless VMs, `machine-akasha.slice`) are built
   in step 6.
2. The host-wide parts (KSM, zswap, swappiness, OOM order, `MemoryLow=`) are decided one by
   one after the RAM gate of step 6 (ADR-0030), from measurements; none is applied before.
3. Host monitoring waits until a Prometheus exists (P5); until then, read-only commands over
   SSH.

### Confirmation

A/B measurement after deployment: KSM profit and ksmd CPU, zswap usage, per-VM RSS,
Galera/RabbitMQ/etcd latency with KSM on and off.

## Updates

* 2026-11-24: on the router (step 6b-4), free page reporting is negotiated and enabled on
  both sides, but returned no memory to `insa`. Its QEMU process kept the whole 512 MiB
  resident while the guest had about 88 MiB free in blocks of 2 MiB or more. The main
  suspect is the host's transparent hugepages `always`, which is a host-wide setting and the
  school's (open question A24, to settle before the RAM gate of step 6d).

## More Information

[research/08-observability-and-host-memory.md](../research/08-observability-and-host-memory.md)
