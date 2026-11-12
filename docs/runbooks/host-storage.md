# Host storage (`vg_akasha` on `nvme0n1p4`)

Layout and rationale: [ADR-0009](../adr/0009-host-disk-layout.md). Managed by the Ansible role
`host_storage` (`infra/ansible/playbooks/host.yml`). All commands below run on `insa` as root
unless stated otherwise.

## Images volume not mounted after boot

- **Symptom:** `/var/lib/libvirt/akasha` is empty or `findmnt /var/lib/libvirt/akasha` prints
  nothing; VMs fail to start ("Cannot access storage file"). The host itself boots, because the
  fstab entry has `nofail`.
- **Impact:** every lab VM whose disk is in the libvirt pool.
- **Diagnosis:**
  ```bash
  systemctl status var-lib-libvirt-akasha.mount
  journalctl -b -u var-lib-libvirt-akasha.mount
  lvs vg_akasha; pvs -a        # pvs -a must list only nvme0n1p4
  lvmconfig devices/global_filter
  blkid /dev/nvme0n1p4         # PARTUUID must match the filter in /etc/lvm/lvmlocal.conf
  ```
- **Mitigation:**
  * VG not found: the LVM filter does not match the partition. Fix
    `/etc/lvm/lvmlocal.conf` (a backup copy sits next to it), then `vgchange -ay vg_akasha`.
  * LV inactive: `vgchange -ay vg_akasha`, then `mount /var/lib/libvirt/akasha`.
  * Filesystem error: `xfs_repair -n /dev/vg_akasha/lv_images` (read-only check first), then
    without `-n` if needed, with the volume unmounted and all VMs stopped.
- **Escalation / rollback:** restore VM disks from backups (P7); never run `xfs_repair -L`
  without understanding the log loss.

## Undo the layout (only while no VM uses it)

```bash
virsh pool-list --all                      # no pool may point to /var/lib/libvirt/akasha
umount /var/lib/libvirt/akasha
sed -i.bak '\|/var/lib/libvirt/akasha|d' /etc/fstab && systemctl daemon-reload
lvremove vg_akasha/lv_images vg_akasha/lv_cinder
vgremove vg_akasha && pvremove /dev/nvme0n1p4
parted /dev/nvme0n1 rm 4                    # partitions 1-3 are not touched
# remove the "akasha host_storage (Ansible)" block from /etc/lvm/lvmlocal.conf
```

## Partition table damaged

- The role saved `sfdisk --dump` output on the owner's laptop before partitioning:
  `~/akasha-private/backups/insa-nvme0n1-<UTC timestamp>.sfdisk`.
- Check it first: `sfdisk --dump /dev/nvme0n1` and compare. GPT also keeps a backup header at
  the end of the disk: `gdisk /dev/nvme0n1` → `r` → `b`/`c` can rebuild from it.
- A full restore rewrites the table of the disk holding `/`: boot a Debian live USB, then
  `sfdisk /dev/nvme0n1 < insa-nvme0n1-<timestamp>.sfdisk`. Never run it on the running host.

## Grow `lv_images`

The VG keeps ~37 GiB free (snapshots first, ADR-0009). XFS grows online:

```bash
vgs vg_akasha                               # check VFree
lvextend -r -L +20G vg_akasha/lv_images     # -r grows the XFS filesystem too
```

Then raise `host_storage_images_size` in the role defaults or `host_vars` (the role never
shrinks a volume).
