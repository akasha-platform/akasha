# Lab VMs: Ansible access and the serial console

Design: [ADR-0035](../adr/0035-access-to-the-lab-vms.md) (access),
[ADR-0026](../adr/0026-ansible-conventions.md) (Ansible), [ADR-0033](../adr/0033-lab-vm-conventions.md)
(VMs). Role `vm_base` (every lab VM), playbook `playbooks/router.yml`.

The VMs are reached as `debian` with the owner's SSH key, at their address on `br-mgmt`
through the tailnet. `debian` has passwordless sudo, so playbooks run without `-K`. Its
password only opens the serial console; SSH refuses passwords and root.

## Once: the console password

In your own terminal, not inside an agent or a recorded session:

```bash
umask 077
h=$(mkpasswd -m yescrypt)                                   # type the password (not shown)
[ "$(mkpasswd -m yescrypt -S "${h%\$*}")" = "$h" ] && echo same   # type it again, from paper
printf "vm_base_console_password_hash: '%s'\n" "$h" > ~/akasha-private/lab_vms.yml
chmod 600 ~/akasha-private/lab_vms.yml; unset h
```

The second `mkpasswd` hashes what you type with the same salt and must print `same`. Keep the
password in GNOME Keyring (Seahorse, "Passwords and Keys", **+**, "Password", named
`akasha lab VMs console`) and on paper. The file holds only the hash; it is never committed.

## Run

```bash
cd ~/Documents/dev/Projets/akasha/infra/ansible
uv run ansible router -m ansible.builtin.ping
uv run ansible-playbook playbooks/router.yml --check --diff -e @~/akasha-private/lab_vms.yml
uv run ansible-playbook playbooks/router.yml --diff -e @~/akasha-private/lab_vms.yml
```

Without the private file the play stops at `Check that the console password hash was passed`
before anything changes. A second run must report `changed=0`.

## Serial console

From the laptop (the owner is in `insa`'s `libvirt` group):

```bash
ssh -t insa 'virsh -c qemu:///system console router'    # press Enter for a prompt; leave with Ctrl+]
```

Log in as `debian` with the console password. The serial log on `insa`
(`/var/log/libvirt/qemu/router-serial.log`) records the console's output, never the typed
password (getty does not echo it).

## Check

```bash
ssh debian@10.10.0.1 'sudo sshd -T | grep -E "^(permitrootlogin|passwordauthentication|kbdinteractiveauthentication) "; sudo passwd -S debian'
ssh -o PubkeyAuthentication=no -o PreferredAuthentications=password,keyboard-interactive debian@10.10.0.1
# expected: Permission denied (publickey).
```

## Change the console password

Run "Once" again (it replaces the file), then the playbook of every lab VM. Update the keyring
item and the paper.

## Add a lab VM to the inventory

Before the first SSH connection, compare the VM's host key with the one printed on its serial
console by cloud-init, then add it to `~/.ssh/known_hosts`:

```bash
ssh insa 'sudo grep -A3 "BEGIN SSH HOST KEY FINGERPRINTS" /var/log/libvirt/qemu/<vm>-serial.log'
ssh-keyscan -t ed25519 <address> 2>/dev/null | ssh-keygen -lf -     # must show the same SHA256
```

Then add the VM under `lab_vms` in `inventories/lab/hosts.yml`.

## Locked out of SSH

- **Symptom:** `ssh debian@<address>` hangs or is refused, Ansible reports `UNREACHABLE`.
- **Diagnosis:** log in on the serial console; `systemctl status ssh`, `sudo sshd -t`,
  `ip -br addr`, `ls /etc/ssh/sshd_config.d/`.
- **Mitigation:** fix or remove the faulty file, then `sudo systemctl reload ssh`.
- **Rollback of vm_base:** `sudo rm /etc/ssh/sshd_config.d/10-akasha.conf && sudo systemctl
  reload ssh`; `sudo passwd -l debian` locks the console password again.
- **Last resort:** rebuild the VM from code (runbook `opentofu-l0.md`:
  `tofu destroy -target=module.router`, then plan and apply), remove its old host key
  (`ssh-keygen -R <address>`), check the new one as in "Add a lab VM", then run its playbook.
