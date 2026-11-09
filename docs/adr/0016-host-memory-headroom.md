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

### Confirmation

A/B measurement after deployment: KSM profit and ksmd CPU, zswap usage, per-VM RSS,
Galera/RabbitMQ/etcd latency with KSM on and off.

## More Information

[research/08-observability-and-host-memory.md](../research/08-observability-and-host-memory.md)
