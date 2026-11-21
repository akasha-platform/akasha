variable "ssh_public_key_file" {
  description = "Public key allowed to log in to the lab VMs (cloud-init default user)."
  type        = string
  default     = "~/.ssh/id_ed25519.pub"
}
