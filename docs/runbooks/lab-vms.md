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
# the other VMs the same way: playbooks/core.yml, playbooks/bastion.yml
```

`core` and `bastion` sit on `br-mgmt` only, behind the router (role `lab_client`):
* the router is their gateway, DNS server (search domain `akasha.internal`) and only time
  source;
* the run prints `insa`'s clock offset, read once through `ptp_kvm` by a separate
  `chronyd -Q`; the running chronyd never uses ptp_kvm (ADR-0029 Updates).

After a host reboot, start the VMs in this order: router, then core, then bastion (ADR-0028).
The router comes first because the others need it to resolve names, keep time and reach the
Internet.

Without the private file the play stops at `Check that the console password hash was passed`
before anything changes. A second run must report `changed=0`.

On a **new VM**, the dry run stops at the first `apt` task with `No package matching ... is
available`. The cloud image has no package lists yet, and a dry run does not download them
(`update_cache`). Only `vm_base` is checked by that dry run; run the playbook for real, since
every role checks its files before writing them and checks the result.

After the first run on a new VM, unattended upgrades soon install a newer kernel than the
image's. Reboot the VM once that is done (`uname -r` against `ls /boot/vmlinuz-*`).

## Serial console

From the laptop (the owner is in `insa`'s `libvirt` group):

```bash
ssh -t insa 'virsh -c qemu:///system console router'    # press Enter for a prompt; leave with Ctrl+]
```

Log in as `debian` with the console password. The serial log on `insa`
(`/var/log/libvirt/qemu/router-serial.log`) records the console's output, never the typed
password (getty does not echo it).

Leave with `Ctrl+]`, not Escape: Escape is sent to the VM as a login name (`^[`, then
`Login incorrect`). If the terminal cannot send `Ctrl+]`, close the SSH session (Enter, `~`, `.`).

`Une session de console active existe pour ce domaine` ("an active console session exists"):
libvirt allows one console session per VM and another one is open, e.g. a virt-manager window
or a forgotten `virsh console`. Close it, or take the console over with
`virsh -c qemu:///system console --force router`.

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

The serial log is appended to across boots and VM rebuilds (`append="on"`), so it also holds
the fingerprints of earlier VMs with the same name. Before destroying a VM you will recreate,
note its length (`ssh -t insa 'sudo wc -l /var/log/libvirt/qemu/<vm>-serial.log'`), and read
only the lines after it:

```bash
ssh -t insa 'sudo tail -n +<length+1> /var/log/libvirt/qemu/<vm>-serial.log | grep -A3 "BEGIN SSH HOST KEY FINGERPRINTS"'
ssh-keyscan -t ed25519 <address> 2>/dev/null > ~/akasha-private/<vm>-hostkey
ssh-keygen -lf ~/akasha-private/<vm>-hostkey          # must show the same SHA256
cat ~/akasha-private/<vm>-hostkey >> ~/.ssh/known_hosts   # only once both match
```

`sudo` on `insa` needs a terminal for its password: `ssh -t`.

Then add the VM under `lab_vms` in `inventories/lab/hosts.yml`.

## Data disk of `core` (ADR-0038)

`core_data` (30 GiB, `core.tf`) is attached as `vdb` and mounted on `/srv` by label
(`akasha-data`, `nofail`). It is a volume of the stack, not of the VM, and it carries
`prevent_destroy`.

```bash
ssh debian@10.10.0.12 'findmnt /srv; df -h /srv'     # /dev/vdb ext4 akasha-data, 30G
```

* **Rebuilding `core`** follows `opentofu-l0.md`, "Rebuilding one VM". The destroy plan lists
  only the four `module.core.` resources, never `libvirt_volume.core_data`. The new VM gets the
  same disk back, and the role `vm_data_disk` finds its own ext4 and only mounts it.
* **The role stops without changing anything** unless `vdb` is either its own ext4 or truly
  blank. Truly blank means no signature for `blkid -p` and zeros in the first and the last MiB.
  It also stops on another size or on partitions. Look at the disk by hand before anything
  else: `sudo blkid -p /dev/vdb; sudo lsblk -f /dev/vdb`. An ext4 whose primary superblock is
  damaged shows no signature: try `sudo e2fsck -n -b 32768 /dev/vdb` (read-only), never
  `mkfs`.
* **Deleting the data on purpose:** remove `prevent_destroy` from `core_data` in a pull
  request, then `tofu destroy -target=libvirt_volume.core_data` with the VM destroyed first.
  The next apply creates a blank disk, which the role formats. Put `prevent_destroy` back in
  the next pull request.
* **Growing the disk** is not possible through OpenTofu (ADR-0038): it is a manual procedure,
  written when needed.

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
