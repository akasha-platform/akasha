# SSH user certificates for the bastion (ADR-0050). The operator logs in from the bastion as the
# userpass user `operator` and gets an 8-hour certificate for the user `debian` of the lab's
# OpenStack nodes, which trust this CA (role ssh_user_ca). The CA key is generated inside
# OpenBao and never leaves it; its public key is committed as infra/pki/ssh-user-ca.pub.
resource "vault_mount" "ssh_client_signer" {
  path        = "ssh-client-signer"
  type        = "ssh"
  description = "SSH user certificates for the lab's VMs (ADR-0050)"
}

resource "vault_ssh_secret_backend_ca" "ssh_client_signer" {
  backend              = vault_mount.ssh_client_signer.path
  generate_signing_key = true
  key_type             = "ed25519"
}

# One login as `debian`, with a terminal, for one working session. No other user, extension,
# critical option or key type can be asked for.
resource "vault_ssh_secret_backend_role" "node" {
  backend                  = vault_mount.ssh_client_signer.path
  name                     = "node"
  key_type                 = "ca"
  allow_user_certificates  = true
  allow_host_certificates  = false
  allowed_users            = "debian"
  default_user             = "debian"
  allowed_extensions       = "permit-pty"
  default_extensions       = { "permit-pty" = "" }
  allowed_critical_options = ""
  ttl                      = 28800 # 8 hours
  max_ttl                  = 28800
  # The key ID names who asked; sshd logs it with each login, and so does OpenBao's audit log.
  key_id_format = "{{token_display_name}}-{{role_name}}"

  allowed_user_key_config {
    type    = "ed25519"
    lengths = [0]
  }
}

resource "vault_policy" "operator" {
  name   = "operator"
  policy = <<-EOT
    # The operator on the bastion (ADR-0050): sign its own SSH key for the OpenStack nodes.
    path "${vault_mount.ssh_client_signer.path}/sign/${vault_ssh_secret_backend_role.node.name}" {
      capabilities = ["update"]
    }
  EOT
}

# The token settings of the userpass user `operator`. The user and its password are created by
# hand first (runbook bastion.md), so the password never reaches the state; this resource
# writes the other fields only and never deletes the user. Logins and tokens work from the
# bastion's address only.
resource "vault_generic_endpoint" "operator_user" {
  path                 = "auth/userpass/users/operator"
  ignore_absent_fields = true
  disable_delete       = true
  data_json = jsonencode({
    token_policies    = [vault_policy.operator.name]
    token_ttl         = 900 # 15 minutes: enough to sign
    token_max_ttl     = 900
    token_type        = "service"
    token_bound_cidrs = ["10.10.0.10"] # one address, as OpenBao returns it (no drift)
  })
}
