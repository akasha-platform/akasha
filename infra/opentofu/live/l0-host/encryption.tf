# Client-side encryption of the state and of plan files (ADR-0007, ADR-0031). The passphrase
# comes from the owner's desktop keyring through an external key provider, never from an
# environment variable or a file; pbkdf2 turns it into the AES-GCM key.
# Never rename these key providers or methods: their names are stored with the encrypted
# data (OpenTofu documentation), and renaming them makes the state unreadable.
terraform {
  encryption {
    key_provider "external" "passphrase" {
      # Run from this directory by OpenTofu, through mise so that the pinned uv (ADR-0022) and
      # the repository's locked environment are used whatever is first on PATH.
      command = ["mise", "exec", "--", "uv", "run", "--locked", "--quiet", "python", "../../scripts/tofu_passphrase.py", "l0"]
    }

    key_provider "pbkdf2" "l0" {
      chain = key_provider.external.passphrase
    }

    method "aes_gcm" "l0" {
      keys = key_provider.pbkdf2.l0
    }

    state {
      method   = method.aes_gcm.l0
      enforced = true
    }

    plan {
      method   = method.aes_gcm.l0
      enforced = true
    }
  }
}
