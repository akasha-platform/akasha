---
status: accepted
date: 2026-11-21
decision-makers: dhuy21
---

# Conventions for the lab's VMs on `insa`

## Context and Problem Statement

Step 6b creates the first VM on the school's host with OpenTofu (provider `dmacvicar/libvirt`
0.9.9, ADR-0007) and cloud-init. Every later VM (bastion, core, controller, computes) will be
built the same way, so the rules are fixed once, in a reusable module
(`infra/opentofu/modules/libvirt-vm`). Research of 2026-11-20 found several provider traps:
the cloud-init ISO lives in the laptop's temporary directory and its loss drops the resource
from state (open question A23); every domain change is applied by shutdown, undefine, define
and start; changing a base image in place deletes it first and then fails (provider issue
#1374); `autostart` changes redefine the VM; the provider uploads images without any checksum.

## Decision Drivers

* Nothing outside akasha's resources on `insa` changes (ADR-0027).
* A routine `tofu plan` must never stop or replace a VM by accident.
* Memory as budgeted (ADR-0030), images whose origin is checked.
* Chosen by the owner on 2026-11-21 (each point below).

## Considered Options

For each topic the options and the research are in the 2026-11-20/21 notes of step 6b; the
owner's choices are recorded below.

## Decision Outcome

* **Connection**: `qemu+sshcmd://insa/system`, the system `ssh` client, so `~/.ssh/config`
  keeps insa's address out of the repository (VERIFIED: provider `docs/transports.md`; `qemu+ssh`
  ignores it). The owner's user is in the `libvirt` group on `insa`, so nothing changes there.
* **Storage**: pool `akasha` in the subdirectory `/var/lib/libvirt/akasha/pool` of the
  `lv_images` mount (ADR-0009), created once by OpenTofu (`build = true`), never deleted
  (`destroy.delete = false`). Not the mount point itself: if `lv_images` is not mounted after a
  reboot, `pool/` is missing and the pool cannot start, instead of libvirt writing VM disks onto
  the school's root file system (independent review, owner's choice of 2026-11-21). Each VM has
  a thin qcow2 overlay on a shared base image, plus a cloud-init seed ISO. Volume permissions
  are set explicitly, since the provider creates volumes 0600 root:root that QEMU cannot open
  (provider issue #1379, met on the first apply of 2026-11-21): base images 0644 (public
  content), each overlay 0600 owned by `libvirt-qemu:kvm` (it holds the VM's data and host
  keys).
* **Images**: pinned in `infra/opentofu/live/l0-host/images.json` (file name, URL, size,
  SHA-512). Debian does not sign its cloud images (VERIFIED: https://cloud.debian.org/images/cloud/,
  no `SHA512SUMS.sign`); the SHA-512 is copied from `SHA512SUMS` over HTTPS when pinning, and
  `scripts/fetch_image.py` downloads the image to the laptop (Debian redirects to a mirror) and
  keeps it only if size and SHA-512 match; OpenTofu uploads that checked local file and refuses a
  cached file that does not match. Releases follow the 6-day cooldown. **A base image is never
  changed in place**: a new release is a new entry and a new volume; base volumes carry
  `prevent_destroy` (owner's choice of 2026-11-21), since overlays depend on them.
* **Domains**: memory in MiB, vCPUs pinned (emulator threads too) to the cores ADR-0030 gives
  them (`16-27`, the E-cores, for the small VMs), `host-passthrough` CPU, q35 with BIOS boot,
  ACPI for a graceful shutdown, `on_crash = restart` with an ISA panic device (x86 has none by
  default), a virtio RNG fed by the host's `/dev/urandom`. **Headless**: one serial console
  (`virsh console`), no graphics, video, sound or USB controller. virtio disk and NICs; NICs on
  the host bridges with fixed MAC addresses, matched by MAC and renamed in cloud-init's
  network-config, so their order does not matter. Free page reporting on the balloon (ADR-0016).
* **cgroup partition** `/machine/akasha` (`machine-akasha.slice`): systemd loads a slice without
  a unit file (VERIFIED: systemd v257 `src/core/slice.c`, `unit_load_fragment_and_dropin(u,
  false)`), so no file is created on `insa` until limits or protections are decided (after the
  RAM gate, ADR-0016).
* **cloud-init**: hostname, network and the owner's public SSH key only, no secret (user-data is
  stored in the state and in a local ISO); password login off; the instance-id is the VM name
  and never changes.
* **A23 guards**: `ignore_changes = [create]` on the volumes built from content (base images,
  seed), so a lost local ISO or a plan from another machine never replaces a disk or stops a VM;
  the cloud-init disk resource may then be recreated locally, which is harmless.
  `ignore_changes = [running]` on domains.
* **Boot policy**: OpenTofu never manages `autostart`. VMs do not start with the host; after a
  host reboot the owner checks the host firewall (runbook `host-firewall.md`) and starts them by
  hand (router first). `libvirt-guests` on Debian shuts running guests down cleanly with the host
  and does not restart them. An `akasha-*` boot unit may replace this in P2.
* **Every apply is followed by a second plan that must show no change** (a perpetual diff would
  restart a VM on every apply).

### Consequences

* Good, because the VMs are rebuilt from code with checked images, and a routine plan cannot
  stop a VM through the provider's known traps.
* Good, because nothing is added to `insa` outside akasha's pool directory and its domains.
* Bad, because the VMs need a manual start after every host reboot.
* Bad, because cloud-init changes after creation are ignored (rebuild the VM instead), and image
  updates mean new volumes and rebuilt VMs.

### Confirmation

Step 6b-1: `virsh dumpxml` shows the pinned CPUs, `host-passthrough`, no graphics or video, a
pty serial, USB `none`, free page reporting, the MACs on the right bridges and the
`/machine/akasha` partition; `systemctl status machine-akasha.slice` is active; a second plan
is empty; the A23 drill (delete the local cloud-init ISO directory, plan) replaces nothing.

## More Information

Provider v0.9.9 source and issues #1344, #1368, #1374, #1378, #1379, #1383; libvirt 11.3.0
`formatdomain` and storage code; Debian libvirt 11.3.0 packaging (libvirtd enabled,
libvirt-guests `ON_BOOT=ignore`); Debian cloud images index.
