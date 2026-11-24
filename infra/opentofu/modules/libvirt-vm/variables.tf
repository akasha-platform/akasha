variable "name" {
  description = "Domain name, also the hostname and the cloud-init instance-id (never change it: cloud-init would run again)."
  type        = string
}

variable "memory_mib" {
  description = "RAM in MiB (ADR-0030)."
  type        = number
}

variable "vcpus" {
  description = "Number of vCPUs."
  type        = number
}

variable "cpu_set" {
  description = "Host CPUs the vCPUs and the emulator threads are pinned to (\"16-27\" for the E-cores), unless vcpu_cpus and emulator_cpu_set override them."
  type        = string
}

variable "disk_gib" {
  description = "Size of the thin root disk in GiB (a qcow2 overlay on the base image)."
  type        = number
}

variable "pool" {
  description = "Storage pool for the root disk and the cloud-init seed."
  type        = string
}

variable "qemu_uid" {
  description = "uid of QEMU's user on the host (libvirt-qemu); owner of the VM's own disk."
  type        = number
}

variable "qemu_gid" {
  description = "gid of the group libvirt gives a running VM's disk (libvirt-qemu on Debian)."
  type        = number
}

variable "base_volume_path" {
  description = "Path of the base image volume on the host (backing store of the root disk)."
  type        = string
}

variable "interfaces" {
  description = "NICs in order: host bridge, fixed MAC (matched by cloud-init's network-config), optional MTU."
  type = list(object({
    bridge = string
    mac    = string
    mtu    = optional(number)
  }))
}

variable "data_disk_path" {
  description = <<-EOT
    Path of a qcow2 data volume attached as vdb, or null for none. The volume belongs to the
    caller, not to this module, so destroying the VM never destroys its data (ADR-0038).
  EOT
  type        = string
  default     = null
}

variable "vcpu_cpus" {
  description = <<-EOT
    Host CPU of each vCPU, in order (one-to-one pinning), or null to let every vCPU float over
    cpu_set. Used for the OpenStack nodes, each on its own sibling P-core threads (ADR-0041).
  EOT
  type        = list(number)
  default     = null

  validation {
    condition = var.vcpu_cpus == null || (
      length(coalesce(var.vcpu_cpus, [])) == var.vcpus
      && length(distinct(coalesce(var.vcpu_cpus, []))) == var.vcpus
    )
    error_message = "vcpu_cpus needs exactly one distinct host CPU per vCPU."
  }
}

variable "emulator_cpu_set" {
  description = "Host CPUs of QEMU's emulator threads, or null for cpu_set."
  type        = string
  default     = null
}

variable "cpu_threads" {
  description = <<-EOT
    Threads per core of the guest's CPU topology (one socket), or null for libvirt's default
    (one thread per core). With 1:1 pinning on sibling threads, 2 tells the guest which vCPUs
    share a core (ADR-0041).
  EOT
  type        = number
  default     = null

  validation {
    condition     = var.cpu_threads == null || var.vcpus % coalesce(var.cpu_threads, 1) == 0
    error_message = "vcpus must be a multiple of cpu_threads."
  }
}

variable "block_disk_serial" {
  description = <<-EOT
    Serial number of the raw block device, so that the guest finds it as
    /dev/disk/by-id/virtio-<serial> whatever its order (ADR-0041). Null for none.
  EOT
  type        = string
  default     = null
}

variable "block_disk_path" {
  description = <<-EOT
    Path of a raw block device on the host attached after the other disks (the controller's
    lv_cinder, ADR-0041), or null for none. It belongs to the host's LVM, not to OpenTofu.
  EOT
  type        = string
  default     = null
}

variable "user_data" {
  description = "cloud-init user-data. Never put a secret here: it is stored in the OpenTofu state and in a local ISO."
  type        = string
}

variable "network_config" {
  description = "cloud-init network-config version 2."
  type        = string
}

variable "partition" {
  description = "cgroup partition of the domain (machine-akasha.slice, ADR-0033)."
  type        = string
  default     = "/machine/akasha"
}
