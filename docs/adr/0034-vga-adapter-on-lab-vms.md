---
status: accepted
date: 2026-11-22
decision-makers: dhuy21
---

# A VGA adapter on every lab VM, still without a display

## Context and Problem Statement

ADR-0030 and ADR-0033 made the lab's VMs headless: no graphics and **no video device**, only a
serial console. On its first boot (2026-11-21/22) the router VM reset in a loop, about once
every 0.94 s, and never reached its kernel:

* The serial log showed GRUB's `Booting 'Debian GNU/Linux'` on every cycle and never the
  `Loading Linux …` line that the same boot entry prints a few commands later (VERIFIED: 531
  `Booting`, 0 `Loading Linux`). Each cycle raised two libvirt `reboot` events.
* The vCPU was sampled in 32-bit protected mode without paging (`CR0=00000011`, `EFER=0`),
  that is firmware or GRUB, never the 64-bit kernel. The panic device and `on_crash` played no
  part, since the kernel never ran.
* The Debian 13 `genericcloud` image (20261111-2659) sets `GRUB_TERMINAL_OUTPUT="gfxterm
  serial"`, so `grub.cfg` runs `terminal_output gfxterm serial` (VERIFIED: read from the image).
  This is a known Debian problem: cloud images do not boot under KVM without a video device
  (Debian bug #906263, 2018; #1021298 for the Vagrant box), and GRUB with `gfxterm serial`
  loops when QEMU has no display and no VGA device (openSUSE bug 1157366). Why GRUB resets the
  guest was not established (INFERRED: a video BIOS call with no video BIOS present).

Test of 2026-11-22: six transient copies of the router (no NIC, root disk read-only), each
with **one** change, booted for 15 s:

| Copy | Change | Resets in 15 s | Reached `Loading Linux` |
|---|---|---|---|
| t0 | none | 34 | no |
| t1 | CPU `host-model` instead of `host-passthrough` | 32 | no |
| t2 | pinned to the P-cores instead of the E-cores | 74 | no |
| t3 | no cloud-init CD-ROM | 34 | no |
| t4 | a VGA adapter | **0** | **yes** |
| t5 | no panic device | 34 | no |

## Decision Drivers

* The VMs boot from the official, checksum-checked Debian image (ADR-0033), unchanged.
* No display listener on `insa` (ADR-0027: akasha opens no listening service).
* Small memory cost (ADR-0030), proven by a test.

## Considered Options

* **A VGA adapter on every VM, without any `graphics` element.** Tested (t4).
* **UEFI firmware (OVMF) instead of SeaBIOS.** GRUB's EFI build might not loop
  (INFERRED, untested); every VM gains an NVRAM file, which libvirt keeps outside akasha's
  pool directory by default, and the whole boot path would have to be tested again.
* **A customised image** whose GRUB writes to the serial port only (e.g. `virt-customize`).
  The image is then no longer the official one checked against Debian's `SHA512SUMS`, and a
  build step for images is added. Changing GRUB later from inside the guest (Ansible) does not
  help the first boot.

## Decision Outcome

Chosen option: **"A VGA adapter on every VM, without any `graphics` element"**, chosen by the
owner on 2026-11-22. The module `libvirt-vm` adds `videos = [{ model = { type = "vga" } }]`
(libvirt's default video memory). There is still no `<graphics>` element, so no VNC or SPICE
server; access stays SSH and the serial console. This replaces "no video device" in ADR-0030
and ADR-0033; everything else in them stands.

### Consequences

* Good, because the official image and BIOS boot stay as they are, and the fix was tested.
* Bad, because each VM gets one more emulated device, and its video memory (libvirt's default
  16 MiB for `vga`, INFERRED to be allocated by the host only when the guest writes to it)
  adds to the QEMU overhead counted in the host's 3 GiB (ADR-0030); the RAM gate of step 6
  measures it.
* Neutral: GRUB in the guests keeps `gfxterm serial`; the serial console still shows GRUB and
  the kernel.

### Confirmation

Step 6b-1: the router boots to a login prompt in its serial log, `virsh dumpxml` shows the
`vga` video model and no `graphics`, and a second plan shows no change. The memory cost is part
of the step-6 RAM gate.

## More Information

* Debian bug #906263: https://lists.debian.org/debian-cloud/2018/08/msg00039.html
* Debian bug #1021298: https://lists.debian.org/debian-cloud/2022/10/msg00000.html
* openSUSE bug 1157366:
  https://lists.opensuse.org/archives/list/bugs@lists.opensuse.org/thread/YCBTZWZHEO26IXHHP7SAPUUDKPZCHKOC
* Provider `dmacvicar/libvirt` 0.9.9 `docs/resources/domain.md`, `devices.videos`.
