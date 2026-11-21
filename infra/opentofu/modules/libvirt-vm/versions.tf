terraform {
  required_version = "~> 1.13.9"

  required_providers {
    libvirt = {
      source  = "dmacvicar/libvirt"
      version = "0.9.9"
    }
  }
}
