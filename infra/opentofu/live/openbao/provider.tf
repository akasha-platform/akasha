# OpenBao through an SSH tunnel to its loopback listener on core, never another address:
#   ssh -N -L 8200:127.0.0.1:8200 debian@10.10.0.12
# The token is the admin's, from VAULT_TOKEN (runbook openbao-pki.md); it is not stored in the
# state. The provider works with a 20-minute child token of it.
provider "vault" {
  address = "http://127.0.0.1:8200"
}
