# OpenStack nodes (ADR-0006, ADR-0041): the controller and two computes, configured later by
# Kolla-Ansible (P2). Each gets its own sibling P-core threads (1:1 pinning, threads=2), its
# emulator threads on the E-cores, and three NICs (management, overlay, provider).
locals {
  os_nodes = {
    "os-ctl01" = {
      memory_mib = 8192 # ADR-0030
      vcpu_cpus  = [0, 1, 2, 3]
      disk_gib   = 60
      last       = 11
      # Cinder's LVM backend (ADR-0009): a raw LV of the host's vg_akasha, created by Ansible
      # (role host_storage), never by OpenTofu.
      block_disk_path = "/dev/vg_akasha/lv_cinder"
      # The guest finds it as /dev/disk/by-id/virtio-lv_cinder, whatever the disk order.
      block_disk_serial = "lv_cinder"
    }
    "os-cmp01" = {
      memory_mib        = 7782 # ADR-0030
      vcpu_cpus         = [4, 5, 6, 7, 8, 9]
      disk_gib          = 100
      last              = 21
      block_disk_path   = null
      block_disk_serial = null
    }
    "os-cmp02" = {
      memory_mib        = 7782 # ADR-0030
      vcpu_cpus         = [10, 11, 12, 13, 14, 15]
      disk_gib          = 100
      last              = 22
      block_disk_path   = null
      block_disk_serial = null
    }
  }
}

# MAC addresses end with the node's last address byte in hexadecimal; the fourth byte names the
# network (0x0a = 10.10/br-mgmt, 0x1e = 10.30/br-tun, 0x14 = 10.20/br-ext), as for the router.
module "os_node" {
  source   = "../../modules/libvirt-vm"
  for_each = local.os_nodes

  name              = each.key
  memory_mib        = each.value.memory_mib
  vcpus             = length(each.value.vcpu_cpus)
  cpu_set           = "0-15" # P-cores of insa; each vCPU is pinned to one of them below
  vcpu_cpus         = each.value.vcpu_cpus
  cpu_threads       = 2
  emulator_cpu_set  = "16-27" # E-cores
  disk_gib          = each.value.disk_gib
  pool              = libvirt_pool.akasha.name
  base_volume_path  = libvirt_volume.debian13.path
  qemu_uid          = local.qemu_uid
  qemu_gid          = local.qemu_gid
  block_disk_path   = each.value.block_disk_path
  block_disk_serial = each.value.block_disk_serial

  interfaces = [
    { bridge = "br-mgmt", mac = format("52:54:00:0a:00:%02x", each.value.last) },
    { bridge = "br-tun", mac = format("52:54:00:1e:00:%02x", each.value.last), mtu = 9000 },
    { bridge = "br-ext", mac = format("52:54:00:14:00:%02x", each.value.last) },
  ]

  user_data = templatefile("${path.module}/templates/user-data.yaml.tftpl", {
    hostname = each.key
    ssh_key  = trimspace(var.ssh_public_key)
  })

  network_config = templatefile("${path.module}/templates/os-node-network.yaml.tftpl", {
    mgmt_mac     = format("52:54:00:0a:00:%02x", each.value.last)
    mgmt_address = "10.10.0.${each.value.last}/24"
    tun_mac      = format("52:54:00:1e:00:%02x", each.value.last)
    tun_address  = "10.30.0.${each.value.last}/24"
    ext_mac      = format("52:54:00:14:00:%02x", each.value.last)
  })
}

# No host thread may serve two nodes: the 1:1 pins must not overlap (ADR-0041).
check "os_node_pins_are_disjoint" {
  assert {
    condition     = length(distinct(flatten([for n in local.os_nodes : n.vcpu_cpus]))) == length(flatten([for n in local.os_nodes : n.vcpu_cpus]))
    error_message = "Two OpenStack nodes are pinned to the same host CPU."
  }
}
