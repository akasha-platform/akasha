# L0: every VM on the host `insa` (router, bastion, core, OpenStack controller and computes),
# applied by the owner from the laptop only (ADR-0007, ADR-0032). See ../../README.md.
terraform {
  required_version = "~> 1.13.9" # >= 1.13.9 and < 1.14 (state-persistence fix, ADR-0031)

  required_providers {
    libvirt = {
      source  = "dmacvicar/libvirt"
      version = "0.9.9" # pinned exactly (ADR-0007)
    }
  }
}
