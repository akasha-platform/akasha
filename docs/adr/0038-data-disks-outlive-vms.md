---
status: accepted
date: 2026-11-24
decision-makers: dhuy21
---

# Data disks of the lab's VMs outlive the VMs

## Context and Problem Statement

The lab's VMs have a single thin root disk, a qcow2 overlay on the base image, created by the
OpenTofu module `libvirt-vm` (ADR-0033). The router keeps no state, and step 6b-4 destroyed
and rebuilt it from code. `core` is different. Its 30 G data disk will hold OpenBao's
storage (every secret, the PKI keys, the Transit keys that encrypt the L2 and L3 states) and
versitygw's objects (CI states, etcd snapshots). What happens to that disk when the VM is
rebuilt, for a new image, a repair or a drill?

## Decision Drivers

* Rebuilding a VM must stay routine. The runbook `opentofu-l0.md`, "Rebuilding one VM", uses
  `tofu destroy -target=module.<vm>`.
* Losing OpenBao's data before off-site backups exist (step 7) is unrecoverable.
* Deleting data must be a deliberate change in code, never a side effect.

## Considered Options

* **The data disk outlives the VM.** It is a volume of the stack, outside the VM module, with
  `prevent_destroy`; the module only attaches it.
* **The data disk belongs to the VM.** It is a volume inside the module, so destroying the VM
  destroys its data.

## Decision Outcome

Chosen option: **"The data disk outlives the VM"**, chosen by the owner on 2026-11-24.

* **The module** `libvirt-vm` takes an optional `data_disk_path`. When it is set, the volume
  is attached as `vdb` (virtio, qcow2, `discard=unmap`). The VM's own resources stay the same
  four: domain, root overlay, cloud-init seed and its ISO.
* **The volume** is declared next to the VM in the stack (`core.tf`: `core_data`, 30 GiB thin
  qcow2 in pool `akasha`).
  * Its owner is 64055:64055 with mode 0600, like a root overlay.
  * It has `prevent_destroy = true`. Deleting the data means removing that line on purpose
    (runbook `lab-vms.md`).
  * `tofu destroy -target=module.core` does not destroy it, because the module depends on
    the volume and not the other way round. The rebuilt VM gets the same volume back.
* **Inside the VM**, the Ansible role `vm_data_disk`:
  1. checks that `vdb` has the expected size and no partitions, and that it is not the root
     disk;
  2. creates ext4 with the label `akasha-data` **only on a blank disk**. Blank means that
     `blkid -p` finds nothing (exit code 2 exactly) **and** that the first and the last MiB
     read as zeros, as a new qcow2 does. "No signature" alone is not enough: ext4 with a
     damaged primary superblock shows none but is recoverable, and `mkfs` never asks under
     Ansible (it checks for an existing file system only on a terminal, e2fsprogs 1.47.2
     `misc/mke2fs.c`). The filesystem module alone would also overwrite an unidentified
     file system;
  3. stops without changing anything on any other state: another file system or label, a
     signature, or data at either end;
  4. mounts the disk on `/srv` by label, with `nofail` and an fsck at boot (`passno 2`).
     Services that need it declare `RequiresMountsFor=/srv` (from step 6c-2).

### Consequences

* Good, because a rebuild of `core` keeps OpenBao and versitygw data, and the same runbook
  rebuilds any VM.
* Good, because data is deleted only through a reviewed change.
* Bad, because a data volume is one more resource per VM with data, and destroying the whole
  stack needs its `prevent_destroy` removed, like the base images.
* Bad, because a disk that outlives the VM also keeps whatever a compromised VM wrote to it.
  A clean start is a deliberate deletion.

### Confirmation

Step 6c-1:
* the plan adds `core_data` and the two VMs, without changing the router;
* `/srv` on `core` is ext4 labelled `akasha-data`, 30 GiB;
* after a marker file is written, `core` is rebuilt with `tofu destroy -target=module.core`
  and an apply. The data volume is not in the destroy plan, the marker is still there, and
  the role did not create a file system.

### Implementation (2026-11-24)

Applied from PR #68.
* **Creation.** The plan added `core_data` and the two VMs (9 resources) and changed nothing
  on the router. A second plan was empty. On the blank disk, the role created ext4
  `akasha-data` and mounted it on `/srv` (`defaults,nofail 0 2`).
* **Durability test.** A marker file was written on `/srv`, and the file system's UUID and
  creation time were recorded. Then `core` was rebuilt through the runbook:
  * the destroy plan held only the four `module.core.` resources, and `core-data.qcow2`
    stayed in the pool;
  * the apply added four resources, and a second plan was empty;
  * the new host key was checked against the serial log, and the playbook ran (then
    `changed=0`).

  The marker's SHA-256, the UUID and the creation time were unchanged, so the disk was
  mounted again and never reformatted.

## More Information

* ADR-0033 (VM conventions), ADR-0011 (OpenBao on `core`), ADR-0012 (versitygw on `core`),
  ADR-0030 (sizes).
* The independent review of step 6c-1 found that the first version treated "no signature
  recognised" as blank. The rule above replaced it before anything ran.
* Before it ran, the role's safety condition was tested on sample states: a blank disk, its
  own ext4, a damaged ext4 (no signature, data at the start), a foreign label, another file
  system, a wrong size, partitions, the root disk.
* The disk cannot be grown through OpenTofu: the provider refuses any update to a volume, and
  a new `capacity` is not a replacement. Growing it is a manual procedure, to write when it is
  needed (`virsh vol-resize`, then `resize2fs`).
