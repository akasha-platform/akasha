# Public: the CSR is saved to infra/pki/akasha-intermediate-ca.csr and signed offline.
output "intermediate_csr" {
  value = vault_pki_secret_backend_intermediate_cert_request.intermediate.csr
}

output "imported_issuers" {
  value = try(vault_pki_secret_backend_intermediate_set_signed.intermediate[0].imported_issuers, [])
}

# Public: committed as infra/pki/ssh-user-ca.pub, which the OpenStack nodes trust (ADR-0050).
output "ssh_user_ca_public_key" {
  value = vault_ssh_secret_backend_ca.ssh_client_signer.public_key
}
