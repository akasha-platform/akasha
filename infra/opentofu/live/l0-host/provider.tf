# libvirt on insa through the system ssh client (`qemu+sshcmd`): only this transport reads
# ~/.ssh/config, so the host alias `insa` keeps its address out of the repository. It needs
# key authentication without a prompt (BatchMode) and insa's host key in known_hosts.
provider "libvirt" {
  uri = "qemu+sshcmd://insa/system"
}
