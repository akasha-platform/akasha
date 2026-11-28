# Kolla-Ansible's passwords (ADR-0052): one KV v2 secret per password, at
# kv/kolla/passwords/<name>, written by kolla-writepwd's code and read by kolla-readpwd's, run
# on the bastion by akasha-kolla-passwords as the userpass user `operator`.
resource "vault_mount" "kv" {
  path        = "kv"
  type        = "kv"
  options     = { version = "2" }
  description = "Key/value secrets of the lab, versioned (KV v2; ADR-0052)"

  # Destroying or replacing the mount deletes every password of the cloud.
  lifecycle {
    prevent_destroy = true
  }
}

resource "vault_policy" "kolla_passwords" {
  name   = "kolla-passwords"
  policy = <<-EOT
    # The operator on the bastion (ADR-0052): read Kolla's passwords, add new ones, and list
    # their names (akasha-kolla-passwords init refuses to run when one exists). No update: a
    # password that exists can never be changed or pushed out of KV v2's 10 versions from the
    # bastion; changing one is the admin's. No delete, undelete, destroy or metadata change.
    path "${vault_mount.kv.path}/data/kolla/passwords/*" {
      capabilities = ["create", "read"]
    }
    path "${vault_mount.kv.path}/metadata/kolla/passwords/" {
      capabilities = ["list"]
    }
  EOT
}
