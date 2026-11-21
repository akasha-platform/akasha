# Edge router of the lab (ADR-0028, ADR-0029): routes between br-transit, br-mgmt and br-ext
# without NAT. Its firewall, DNS and time are configured by Ansible (playbooks/router.yml);
# until then IPv4 forwarding stays off (kernel default), so it routes nothing.
locals {
  # QEMU's user on insa: libvirt-qemu (fixed uid 64055 in Debian) and its group kvm (gid 993,
  # read on insa with getent on 2026-11-21).
  qemu_uid = 64055
  qemu_gid = 993

  router_nics = {
    wan  = { bridge = "br-transit", mac = "52:54:00:ff:ff:02", address = "10.255.255.2/29" }
    mgmt = { bridge = "br-mgmt", mac = "52:54:00:0a:00:01", address = "10.10.0.1/24" }
    ext  = { bridge = "br-ext", mac = "52:54:00:14:00:01", address = "10.20.0.1/24" }
  }
}

module "router" {
  source = "../../modules/libvirt-vm"

  name             = "router"
  memory_mib       = 512 # ADR-0030
  vcpus            = 1
  cpu_set          = "16-27" # E-cores of insa
  disk_gib         = 8
  pool             = libvirt_pool.akasha.name
  base_volume_path = libvirt_volume.debian13.path
  qemu_uid         = local.qemu_uid
  qemu_gid         = local.qemu_gid

  interfaces = [
    for name in ["wan", "mgmt", "ext"] : {
      bridge = local.router_nics[name].bridge
      mac    = local.router_nics[name].mac
    }
  ]

  user_data = templatefile("${path.module}/templates/user-data.yaml.tftpl", {
    hostname = "router"
    ssh_key  = trimspace(var.ssh_public_key)
  })

  network_config = templatefile("${path.module}/templates/router-network.yaml.tftpl", {
    nics = local.router_nics
  })
}
