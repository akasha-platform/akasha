# One headless KVM guest on insa (ADR-0033): thin qcow2 overlay on a base image, cloud-init
# NoCloud seed, virtio NICs on host bridges, serial console only, free page reporting.
#
# provider dmacvicar/libvirt 0.9.9 caveats handled here (open question A23):
# - the cloud-init ISO lives in the laptop's temp directory; when it disappears the provider
#   drops libvirt_cloudinit_disk from state and plans to recreate it (local only). The volumes
#   built from content ignore `create`, so that never replaces a disk or stops the VM.
# - every change of the domain is applied by shutdown, undefine, define and start: after an
#   apply, a second plan must show no change.
# - `autostart` is never managed here (changing it redefines the VM; the boot policy is in the
#   runbook, ADR-0033).

locals {
  meta_data = "instance-id: ${var.name}\nlocal-hostname: ${var.name}\n"
}

resource "libvirt_volume" "root" {
  name     = "${var.name}-root.qcow2"
  pool     = var.pool
  capacity = var.disk_gib * 1024 * 1024 * 1024

  target = {
    format = { type = "qcow2" }
  }

  backing_store = {
    path   = var.base_volume_path
    format = { type = "qcow2" }
  }
}

resource "libvirt_cloudinit_disk" "seed" {
  name           = "${var.name}-seed"
  user_data      = var.user_data
  meta_data      = local.meta_data
  network_config = var.network_config
}

resource "libvirt_volume" "seed" {
  name = "${var.name}-seed.iso"
  pool = var.pool

  target = {
    format = { type = "iso" } # "raw" makes libvirt detect iso and the apply fail (provider #1378)
  }

  create = {
    content = { url = libvirt_cloudinit_disk.seed.path }
  }

  lifecycle {
    # The ISO path is a local temporary file (A23); the seed is read once at first boot.
    ignore_changes = [create]
  }
}

resource "libvirt_domain" "this" {
  name        = var.name
  type        = "kvm"
  memory      = var.memory_mib
  memory_unit = "MiB"
  vcpu        = var.vcpus
  running     = true
  on_crash    = "restart"

  cpu = { mode = "host-passthrough" }

  cpu_tune = {
    vcpu_pin     = [for i in range(var.vcpus) : { vcpu = i, cpu_set = var.cpu_set }]
    emulator_pin = { cpu_set = var.cpu_set }
  }

  os = {
    type         = "hvm"
    type_arch    = "x86_64"
    type_machine = "q35"
  }

  features = {
    acpi = true # needed for a graceful shutdown
  }

  resource = { partition = var.partition }

  devices = {
    disks = [
      {
        source = { volume = { pool = var.pool, volume = libvirt_volume.root.name } }
        target = { dev = "vda", bus = "virtio" }
        driver = { name = "qemu", type = "qcow2", discard = "unmap" }
      },
      {
        device    = "cdrom"
        read_only = true
        source    = { volume = { pool = var.pool, volume = libvirt_volume.seed.name } }
        target    = { dev = "sda", bus = "sata" }
      },
    ]

    interfaces = [
      for nic in var.interfaces : {
        mac    = { address = nic.mac }
        model  = { type = "virtio" }
        source = { bridge = { bridge = nic.bridge } }
        mtu    = nic.mtu == null ? null : { size = nic.mtu }
      }
    ]

    # Headless: a serial console only (virsh console), no graphics, video, sound or USB.
    serials     = [{ target = { port = 0 } }]
    controllers = [{ type = "usb", model = "none" }]

    # Lets on_crash act on a guest kernel panic (x86 gets no panic device by default).
    panics = [{ model = "isa" }]

    # Entropy from the host for the guest's early boot (key generation).
    rngs = [{ model = "virtio", backend = { random = "/dev/urandom" } }]

    mem_balloon = {
      model               = "virtio"
      free_page_reporting = "on"
      stats               = { period = 10 }
    }
  }

  update  = { shutdown = { timeout = 60 } }
  destroy = { shutdown = { timeout = 60 } }

  lifecycle {
    ignore_changes = [running] # the owner starts and stops VMs by hand after a host reboot
  }
}
