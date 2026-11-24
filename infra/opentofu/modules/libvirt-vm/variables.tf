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
  description = "Host CPUs the vCPUs and the emulator threads are pinned to, e.g. \"16-27\" for the E-cores."
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
