# The machine identity of core's daily backup (ADR-0049): an AppRole that may only take a Raft
# snapshot. Its secret_id is generated on core by akasha-bao-approle (admin token on stdin)
# and never leaves it; logins and tokens work from 127.0.0.1 only.
resource "vault_auth_backend" "approle" {
  type        = "approle"
  path        = "approle"
  description = "Machine identities of the lab (ADR-0049)"
}

resource "vault_policy" "raft_snapshot" {
  name   = "raft-snapshot"
  policy = <<-EOT
    # Take a snapshot of OpenBao's Raft storage (core's daily backup, ADR-0049).
    path "sys/storage/raft/snapshot" {
      capabilities = ["read"]
    }
  EOT
}

resource "vault_approle_auth_backend_role" "core_backup" {
  backend               = vault_auth_backend.approle.path
  role_name             = "core-backup"
  token_policies        = [vault_policy.raft_snapshot.name]
  token_ttl             = 300 # 5 minutes: one snapshot
  token_max_ttl         = 600
  token_bound_cidrs     = ["127.0.0.1/32"] # AppRole wants CIDRs; the provider absorbs OpenBao storing 127.0.0.1
  secret_id_bound_cidrs = ["127.0.0.1/32"]
  token_type            = "service"
}
