# Bastion (ADR-0032, overview): runs OpenTofu, Ansible and Kolla inside the lab, and later the
# CI wrapper. On br-mgmt only; routed, resolved and timed by the router (Ansible role
# lab_client). Its 1 GiB swap file is made by Ansible (role vm_swap, ADR-0030).
module "bastion" {
  source = "../../modules/libvirt-vm"

  name             = "bastion"
  memory_mib       = 768 # ADR-0030
  vcpus            = 1
  cpu_set          = "16-27" # E-cores of insa
  disk_gib         = 20
  pool             = libvirt_pool.akasha.name
  base_volume_path = libvirt_volume.debian13.path
  qemu_uid         = local.qemu_uid
  qemu_gid         = local.qemu_gid

  interfaces = [{ bridge = "br-mgmt", mac = "52:54:00:0a:00:0a" }]

  user_data = templatefile("${path.module}/templates/user-data.yaml.tftpl", {
    hostname = "bastion"
    ssh_key  = trimspace(var.ssh_public_key)
  })

  network_config = templatefile("${path.module}/templates/vm-network.yaml.tftpl", {
    mac     = "52:54:00:0a:00:0a"
    address = "10.10.0.10/24"
  })
}
