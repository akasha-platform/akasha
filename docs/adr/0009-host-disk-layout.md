---
status: accepted
date: 2026-11-08
decision-makers: dhuy21
---

# Host disk layout on LVM

## Context and Problem Statement

VM disks total ≈ 346 GB thin-provisioned (OPNsense 16, bastion 20, core 20 + 30 data,
ctl01 60, computes 2 × 100) and Cinder needs a dedicated block device. The root filesystem
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

### Implementation

Ansible role `host_storage` (`infra/ansible/roles/host_storage`, playbook `playbooks/host.yml`,
disk values in `inventories/lab/host_vars/insa.yml`), decided on 2026-11-12:

* **Guards**: the role stops, without changing anything, unless the disk is GPT, has the
  measured size, has exactly partitions 1–3 with p3 ending at 488386 MiB, and
  `devices/scan_lvs=0`. Partition 4 is created only with `-e host_storage_confirm=nvme0n1`.
* `community.general.parted` is called with `label: gpt`: its default (`msdos`) differs from
  the disk label, and the module would then write a new, empty partition table
  (`mklabel_needed` in `parted.py`, community.general 13.5.1). The dry run prints the parted
  script, which must not contain `mklabel`.
* The partition table is dumped with `sfdisk --dump` to the owner's laptop
  (`~/akasha-private/backups/`) before partitioning.
* **LVM filter**: `global_filter = [ "a|^/dev/disk/by-partuuid/<p4>$|", "r|.*|" ]` in
  `/etc/lvm/lvmlocal.conf` (overrides `lvm.conf`, untouched by lvm2 package upgrades). The
  PARTUUID does not change when another disk is added. `scan_lvs=0` (lvm2 default, checked
  by the role) already keeps the host out of the guest VG inside `lv_cinder`; the whitelist
  also hides loop and nbd devices (a guest qcow2 attached for recovery) from the host. The
  role waits for the `by-partuuid` link and checks that `pvs -a` lists only p4 before creating
  the PV (on the first run, 2026-11-13, the link was not there yet right after `udevadm settle`;
  the run stopped at this check before any PV was created). Boot activation with this filter is
  open question A16.
* `lvol` with `shrink: false`, `lvg` with `remove_extra_pvs: false`; fstab entry by UUID with
  `defaults,nofail`, checked with `findmnt --verify`.

### Consequences

* Good, because no existing data is touched and snapshots are possible.
* Accepted over-allocation: the thin total (≈ 346 GB) exceeds `lv_images` (320 GiB); real usage
  is expected far lower. Pool usage is monitored and `lv_images` can grow from the VG free space.
* Bad, because the partitioning step is irreversible without care; it is done in its own étape.
