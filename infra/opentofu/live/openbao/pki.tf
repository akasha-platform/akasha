# The lab's intermediate CA (ADR-0019, ADR-0044, ADR-0046). Two applies:
# 1. the mount, the URLs, the role and a CSR whose key is generated inside OpenBao and never
#    leaves it (output `intermediate_csr`, saved to infra/pki/);
# 2. once the offline root has signed it on the laptop (runbook openbao-pki.md), the signed
#    certificate in infra/pki/ is imported with the root as its chain.

locals {
  pki_dir           = "${path.module}/../../../pki"
  intermediate_cert = "${local.pki_dir}/akasha-intermediate-ca.crt"
  root_cert         = "${local.pki_dir}/akasha-root-ca.crt"
  # Reachable once step 7d-2 opens OpenBao's TLS listener.
  base_url = "https://core.akasha.internal:8200/v1/pki"
}

resource "vault_mount" "pki" {
  path                      = "pki"
  type                      = "pki"
  description               = "akasha's intermediate CA, signed by the offline root (ADR-0046)"
  default_lease_ttl_seconds = 2592000  # 30 days
  max_lease_ttl_seconds     = 31536000 # 1 year: the longest end-entity certificate

  # Destroying or replacing the mount deletes the intermediate's key.
  lifecycle {
    prevent_destroy = true
  }
}

resource "vault_pki_secret_backend_intermediate_cert_request" "intermediate" {
  backend      = vault_mount.pki.path
  type         = "internal" # the key stays inside OpenBao
  common_name  = "akasha Intermediate CA"
  organization = "akasha"
  key_type     = "ec"
  key_bits     = 384
  key_name     = "intermediate-2026"

  # A new request means a new key: the signed certificate would no longer match it.
  lifecycle {
    prevent_destroy = true
  }
}

# The signed intermediate followed by the root. OpenBao imports both as issuers, links the
# intermediate to its key and makes it the default issuer; the root has no key here.
resource "vault_pki_secret_backend_intermediate_set_signed" "intermediate" {
  count       = fileexists(local.intermediate_cert) ? 1 : 0
  backend     = vault_mount.pki.path
  certificate = fileexists(local.intermediate_cert) ? "${file(local.intermediate_cert)}${file(local.root_cert)}" : ""
}

resource "vault_pki_secret_backend_config_urls" "urls" {
  backend                 = vault_mount.pki.path
  issuing_certificates    = ["${local.base_url}/ca"]
  crl_distribution_points = ["${local.base_url}/crl"]
}

# Server certificates for the lab's names and 10.x addresses, one year at most. Written through
# the generic endpoint: the Vault provider's role resource lacks OpenBao's
# `allowed_ip_sans_cidr`. TTLs are in seconds, as OpenBao returns them (no drift).
resource "vault_generic_endpoint" "role_server" {
  path                 = "${vault_mount.pki.path}/roles/server"
  ignore_absent_fields = true
  data_json = jsonencode({
    allowed_domains             = ["akasha.internal"]
    allow_subdomains            = true
    allow_bare_domains          = false
    allow_glob_domains          = false
    allow_wildcard_certificates = false
    allow_localhost             = false
    enforce_hostnames           = true
    allow_ip_sans               = true
    allowed_ip_sans_cidr        = ["10.0.0.0/8"]
    allowed_uri_sans            = []
    server_flag                 = true
    client_flag                 = false
    key_type                    = "ec"
    key_bits                    = 256
    key_usage                   = ["DigitalSignature"]
    ttl                         = 2592000  # 30 days
    max_ttl                     = 31536000 # 1 year
    no_store                    = false
  })
}
