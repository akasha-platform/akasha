locals {
  # Owner that libvirt gives a VM's disk while the VM runs: Debian builds libvirt with
  # qemu_user and qemu_group libvirt-qemu (uid and gid 64055, read on insa with getent on
  # 2026-11-22), and insa's qemu.conf does not override them. Declaring the same owner keeps
  # plans empty while a VM runs (ADR-0033 Updates).
  qemu_uid = 64055
  qemu_gid = 64055
}
