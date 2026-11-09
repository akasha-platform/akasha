---
status: accepted
date: 2026-11-08
decision-makers: dhuy21
---

# Host disk layout on LVM

## Context and Problem Statement

VM disks need ~340 GB (thin) and Cinder needs a dedicated block device. The root filesystem
has ~145 GB free; 477 GiB at the end of the NVMe are unallocated.

## Decision Outcome

Create partition 4 on the free space → LVM PV → VG `vg_akasha`:

* `lv_images` 320 GiB, XFS, mounted at `/var/lib/libvirt/akasha` → libvirt dir pool of thin qcow2
* `lv_cinder` 120 GiB raw → attached to `os-ctl01`, guest VG `cinder-volumes`
  (host `lvm.conf` `global_filter` prevents activating the guest VG on the host)
* ~37 GiB left free for LVM snapshots before risky operations

libvirt `logical` pools were rejected (thick provisioning with the current provider).
The existing NVMe swap partition stays; zswap sits in front of it with `vm.swappiness` ≈ 80
(see ADR-0016, which supersedes the earlier "low swappiness" idea).

### Consequences

* Good, because no existing data is touched and snapshots are possible.
* Bad, because the partitioning step is irreversible without care; it is done in its own étape.
