# Core (ADR-0011, ADR-0012): OpenBao and versitygw, on br-mgmt only (never reachable from
# br-ext, ADR-0028). Routed, resolved and timed by the router (Ansible role lab_client).

# Data disk (OpenBao's storage, versitygw's objects): a volume of this stack, not of the VM
# module, so that destroying or rebuilding the VM (`tofu destroy -target=module.core`) keeps
# it (ADR-0038). Formatted and mounted on /srv by Ansible (role vm_data_disk), never
# reformatted.
resource "libvirt_volume" "core_data" {
  name     = "core-data.qcow2"
  pool     = libvirt_pool.akasha.name
  capacity = 30 * 1024 * 1024 * 1024

  target = {
    format = { type = "qcow2" }
    # Same owner and mode as a root overlay (module libvirt-vm): private to QEMU's user, and
    # what libvirt sets while the VM runs, so plans stay empty.
    permissions = {
      owner = tostring(local.qemu_uid)
      group = tostring(local.qemu_gid)
      mode  = "0600"
    }
  }

  lifecycle {
    # Refuse any plan that destroys the data. Remove this line only to delete core's data on
    # purpose (docs/runbooks/lab-vms.md).
    prevent_destroy = true
  }
}

module "core" {
  source = "../../modules/libvirt-vm"

  name             = "core"
  memory_mib       = 614 # ADR-0030
  vcpus            = 1
  cpu_set          = "16-27" # E-cores of insa
  disk_gib         = 20
  pool             = libvirt_pool.akasha.name
  base_volume_path = libvirt_volume.debian13.path
  qemu_uid         = local.qemu_uid
  qemu_gid         = local.qemu_gid
  data_disk_path   = libvirt_volume.core_data.path

  interfaces = [{ bridge = "br-mgmt", mac = "52:54:00:0a:00:0c" }]

  user_data = templatefile("${path.module}/templates/user-data.yaml.tftpl", {
    hostname = "core"
    ssh_key  = trimspace(var.ssh_public_key)
  })

  network_config = templatefile("${path.module}/templates/vm-network.yaml.tftpl", {
    mac     = "52:54:00:0a:00:0c"
    address = "10.10.0.12/24"
  })
}
