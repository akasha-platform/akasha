variable "ssh_public_key" {
  description = <<-EOT
    Public key allowed to log in to the lab VMs (cloud-init default user). Passed at run time,
    never stored in the repository (its comment may name the owner):
      export TF_VAR_ssh_public_key="$(cat ~/.ssh/id_ed25519.pub)"
  EOT
  type        = string
  nullable    = false

  validation {
    condition     = can(regex("^ssh-ed25519 [A-Za-z0-9+/=]+( .*)?$", trimspace(var.ssh_public_key)))
    error_message = "ssh_public_key must be one ssh-ed25519 public key line."
  }
}
