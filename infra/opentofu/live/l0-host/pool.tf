# Storage pool in a subdirectory of the lv_images mount (ADR-0009, ADR-0033). The pool is not
# the mount point itself: when lv_images is not mounted after a reboot, `pool/` does not exist
# on the host's root file system, so libvirt cannot start the pool (fail closed) instead of
# writing VM disks onto the school's root file system. `build` creates `pool/` once, on the
# mounted volume; destroy only undefines the pool and never deletes the directory.
resource "libvirt_pool" "akasha" {
  name = "akasha"
  type = "dir"

  target = { path = "/var/lib/libvirt/akasha/pool" }

  create = {
    build     = true
    start     = true
    autostart = true
  }

  destroy = { delete = false }
}
