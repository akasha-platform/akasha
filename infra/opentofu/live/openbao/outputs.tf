# Public: the CSR is saved to infra/pki/akasha-intermediate-ca.csr and signed offline.
output "intermediate_csr" {
  value = vault_pki_secret_backend_intermediate_cert_request.intermediate.csr
}

output "imported_issuers" {
  value = try(vault_pki_secret_backend_intermediate_set_signed.intermediate[0].imported_issuers, [])
}
