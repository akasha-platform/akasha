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
  role waits for the `by-partuuid` link and checks that `pvs -a -o pv_name,vg_name` lists only
  p4 before creating the PV. `vg_name` is required: with `-o pv_name` alone, `pvs` reports
  labelled PVs only and ignores `-a` (report type LABEL, `tools/reporter.c`, lvm2 2.03.31), which
  stopped the first two runs on 2026-11-13 at this check, before any PV was created.
* `lvol` with `shrink: false`, `lvg` with `remove_extra_pvs: false`; fstab entry by UUID with
  `defaults,nofail`, checked with `findmnt --verify`.

### Consequences

* Good, because no existing data is touched and snapshots are possible.
* Accepted over-allocation: the thin total (≈ 346 GB) exceeds `lv_images` (320 GiB); real usage
  is expected far lower. Pool usage is monitored and `lv_images` can grow from the VG free space.
* Bad, because the partitioning step is irreversible without care; it is done in its own étape.

### Confirmation

On 2026-11-13, `playbooks/host.yml` (role `host_storage`, after the fixes of PR #22 and #23):

* Dry run (`--check --diff`) printed the parted script `mkpart primary 488386MiB 100%`,
  `name 4 "akasha"`, `set 4 lvm on`, without `mklabel`; the `sfdisk --dump` was saved on the
  laptop before the confirmed run.
* `parted print`: partitions 1–3 unchanged; p4 488386–976762 MiB (488376 MiB), name `akasha`,
  flag `lvm`.
* `pvs -a` lists only the PARTUUID path of p4 (member of `vg_akasha`); `vg_akasha` 476.93 GiB
  with 36.93 GiB free; `lv_images` 320 GiB and `lv_cinder` 120 GiB.
* `lv_images` is XFS, mounted on `/var/lib/libvirt/akasha` (`var-lib-libvirt-akasha.mount`
  active), fstab entry by UUID with `defaults,nofail`; `findmnt --verify` passes. The empty
  filesystem shows 6.2 GiB used (XFS log and metadata reservations).
* A second run reports `changed=0`.
* After the host upgrade to Debian 13.7 and a reboot (kernel 6.12.116, 2026-11-13): the boot
  log shows `PV /dev/nvme0n1p4 online, VG vg_akasha is complete`, both LVs are active,
  `lv_images` is mounted, `pvs -a` still lists only p4, and the playbook reports `changed=0`.
