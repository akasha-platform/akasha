# The token settings of the userpass user `admin` (ADR-0045, ADR-0047). The user and its
# password come from akasha-bao-bootstrap; this resource writes the other fields only, so the
# password never reaches the state, and never deletes the user. Tokens may be used and the
# user may log in from 127.0.0.1 only: over SSH on core, or through OpenTofu's SSH tunnel.
resource "vault_generic_endpoint" "admin_user" {
  path                 = "auth/userpass/users/admin"
  ignore_absent_fields = true
  disable_delete       = true
  data_json = jsonencode({
    token_policies    = ["admin"]
    token_ttl         = 3600  # 1 hour
    token_max_ttl     = 14400 # 4 hours
    token_type        = "service"
    token_bound_cidrs = ["127.0.0.1"] # one address, as OpenBao returns it (no drift)
  })
}
