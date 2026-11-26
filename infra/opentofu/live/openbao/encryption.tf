# Client-side encryption of the state and of plan files (ADR-0007, ADR-0031, ADR-0046), as in
# the L0 stack but with the passphrase `openbao` of the desktop keyring, never an environment
# variable or a file; pbkdf2 turns it into the AES-GCM key. Key-provider metadata is stored
# with the encrypted data under `encrypted_metadata_alias`: never change the aliases. Rotation:
# as for L0 (docs/runbooks/opentofu-l0.md, "Rotate the passphrase").
terraform {
  encryption {
    key_provider "external" "passphrase" {
      encrypted_metadata_alias = "openbao-passphrase"
      # Run from this directory by OpenTofu, through mise so that the pinned uv (ADR-0022) and
      # the repository's locked environment are used whatever is first on PATH.
      command = ["mise", "exec", "--", "uv", "run", "--locked", "--quiet", "python", "../../scripts/tofu_passphrase.py", "openbao"]
    }

    key_provider "pbkdf2" "openbao" {
      encrypted_metadata_alias = "openbao-pbkdf2"
      chain                    = key_provider.external.passphrase
    }

    method "aes_gcm" "openbao" {
      keys = key_provider.pbkdf2.openbao
    }

    state {
      method   = method.aes_gcm.openbao
      enforced = true
    }

    plan {
      method   = method.aes_gcm.openbao
      enforced = true
    }
  }
}
