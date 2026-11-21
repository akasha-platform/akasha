# Storage pool on the lv_images mount (ADR-0009). The directory already exists and belongs to
# the host's storage layout: OpenTofu never builds nor deletes it (destroy only undefines).
resource "libvirt_pool" "akasha" {
  name = "akasha"
  type = "dir"

  target = { path = "/var/lib/libvirt/akasha" }

  create = {
    build     = false
    start     = true
    autostart = true
  }

  destroy = { delete = false }
}
