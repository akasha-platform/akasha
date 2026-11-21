# Base images, pinned in images.json and fetched and checked on the laptop by
# scripts/fetch_image.py before an apply (ADR-0033). A base image is never changed in place:
# a new release is a new entry and a new volume (provider issue #1374).
locals {
  images    = jsondecode(file("${path.module}/images.json"))
  image_dir = pathexpand("~/.cache/akasha/images")
  debian13  = "${local.image_dir}/${local.images.debian13.file}"
}

resource "libvirt_volume" "debian13" {
  name = local.images.debian13.file
  pool = libvirt_pool.akasha.name

  target = {
    format = { type = "qcow2" }
  }

  create = {
    content = { url = local.debian13 }
  }

  lifecycle {
    ignore_changes = [create] # uploaded once; the local copy may be gone later (A23)
    # Overlays depend on this volume, and the provider deletes a replaced volume first
    # (issue #1374): refuse any plan that destroys it. Remove this line only to destroy the
    # whole stack on purpose (docs/runbooks/opentofu-l0.md).
    prevent_destroy = true

    precondition {
      condition     = !fileexists(local.debian13) || filesha512(local.debian13) == local.images.debian13.sha512
      error_message = "The cached Debian image does not match images.json: delete it and run scripts/fetch_image.py debian13."
    }
  }
}
