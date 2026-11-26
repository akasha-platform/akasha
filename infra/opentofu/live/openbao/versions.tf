# OpenBao's configuration (ADR-0046): the PKI intermediate CA and its roles. Applied by the
# owner from the laptop only, through an SSH tunnel to OpenBao's loopback listener on core.
# See docs/runbooks/openbao-pki.md.
terraform {
  required_version = "~> 1.13.9" # >= 1.13.9 and < 1.14 (state-persistence fix, ADR-0031)

  required_providers {
    vault = {
      # OpenBao has no provider of its own yet (OpenBao RFC "dedicated-tf-provider"); the
      # Vault provider works for these resources, tested against OpenBao 2.7.3 (ADR-0046).
      source  = "hashicorp/vault"
      version = "5.13.0" # pinned exactly (ADR-0007); 5.14.0 was inside the cooldown
    }
  }
}
