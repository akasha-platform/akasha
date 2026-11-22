---
status: accepted
date: 2026-11-22
decision-makers: dhuy21
---

# Access to the lab's VMs: SSH keys, a console password and passwordless sudo

## Context and Problem Statement

From step 6b-2 on, Ansible configures the lab's VMs from the owner's laptop (ADR-0026), first
the edge router (ADR-0028). Three questions were open:

* **Console.** ADR-0028 names `virsh console` (over SSH to `insa`) as the way into the router
  when the lab's network is down. The Debian 13 cloud image locks every password (`passwd -S`
  shows `L` for `debian` and `root`, VERIFIED on the router on 2026-11-22), so the console
  shows a login prompt nobody can pass.
* **Privilege escalation.** cloud-init gives `debian` passwordless sudo
  (`/etc/sudoers.d/90-cloud-init-users`, VERIFIED on the router). ADR-0026 runs Ansible
  with the sudo password prompted (`-K`) on `insa`.
* **Inventory.** ADR-0026 reaches hosts through SSH aliases, so that no address is committed.
  The VMs have lab-internal addresses (10.x), which the public repository may contain
  (CLAUDE.md), reached from the laptop through the tailnet (subnet routes, step 4c).

The image already accepts SSH keys only (`passwordauthentication no`,
`kbdinteractiveauthentication no`) but allows root with a key
(`permitrootlogin without-password`), and cloud-init writes these settings in its own file
(`/etc/ssh/sshd_config.d/50-cloud-init.conf`), all VERIFIED with `sshd -T` on the router.

## Decision Drivers

* A way into a VM that does not depend on the lab's network (ADR-0028).
* No secret in the repository, in cloud-init user-data or in the OpenTofu state (ADR-0033).
* Few secrets to keep: the owner works alone from one laptop.
* A password that exists must never be usable over the network.

## Considered Options

Console:

* **No password**: the console is useless; recovery means rebuilding the VM or editing its
  disk from `insa` with the VM stopped.
* **A password for the console only**, SSH by key only. Chosen.
* **A password for the console and SSH**: a password reachable over the network. Rejected.

Privilege escalation:

* **Passwordless sudo** (the image's default), as the default users of the major cloud
  images do (INFERRED from the Debian, Ubuntu and Amazon Linux images): reaching `debian`
  already requires the owner's SSH key or the console password. Chosen.
* **sudo with a password** (`-K`): one more secret per run and per VM, and the account is
  still reached only with the key.

Inventory:

* **Lab addresses in the inventory** (`ansible_host: 10.10.0.1`). Chosen.
* **SSH aliases** as for `insa`: one more file to keep in sync on the laptop, for addresses
  that are not secret.
* **Names in `akasha.internal`**: the router serves that zone (step 6b-3) and is itself the
  first VM to configure, and Ansible would then depend on the lab's DNS.

## Decision Outcome

Chosen by the owner on 2026-11-22, in the Ansible role `vm_base`, applied to every lab VM:

* **Console password**: the default user `debian` gets a password, set by Ansible from a
  yescrypt hash. The hash comes from a private file on the laptop
  (`~/akasha-private/lab_vms.yml`, mode 0600, passed with `-e @…`), never from the repository
  or cloud-init; the role stops before any change when it is missing or not a yescrypt hash.
  The owner creates the hash in their own terminal (`mkpasswd -m yescrypt`) and keeps the
  password in GNOME Keyring and on paper, like the L0 passphrase. One password serves all lab
  VMs: the console is reached only through SSH to `insa` as a member of its `libvirt` group.
  `root` stays locked.
* **SSH**: keys only, never root. The role installs `/etc/ssh/sshd_config.d/10-akasha.conf`
  (`PermitRootLogin no`, `PasswordAuthentication no`, `KbdInteractiveAuthentication no`),
  checked with `sshd -t` before it replaces anything. sshd keeps the first value it reads and
  reads the drop-ins in name order (`Include` at the top of Debian's `sshd_config`), so this
  file wins over cloud-init's. The password is set **before** sshd is touched, so the console
  works if the SSH change goes wrong; Debian's `ssh.service` also runs `sshd -t` before a
  reload (VERIFIED: openssh 1:10.0p1-7+deb13u4 `debian/systemd/ssh.service`).
* **sudo**: passwordless, as cloud-init sets it; the role checks it is there and does not
  manage it. Playbooks for lab VMs run without `-K`.
* **Inventory**: group `lab_vms` with `ansible_user: debian` and each VM by its address on
  `br-mgmt`. A VM's host key is added to `~/.ssh/known_hosts` only after its fingerprint is
  compared with the one on its serial console (done for the router in step 6b-1); host key
  checking stays on.
* `vm_base` also checks, without changing them, the image defaults the lab relies on:
  Debian 13, UTC, unattended upgrades enabled, `ssh.service` running.

### Consequences

* Good, because a VM can be reached when its network or sshd is broken, and that password is
  refused by SSH.
* Good, because no secret enters the repository, the user-data or the state.
* Bad, because whoever holds the owner's SSH key is root on every lab VM without a second
  factor; the same holds for `insa`'s Tailscale access and the key is the owner's to protect.
* Bad, because one console password serves all VMs: changing it means a new hash and a run
  on every VM (runbook `lab-vms.md`).

### Confirmation

Step 6b-2, on the router: a second run reports `changed=0`; `sshd -T` shows
`permitrootlogin no`, `passwordauthentication no`, `kbdinteractiveauthentication no`;
`passwd -S debian` shows `P`; an SSH login without a key is refused with
`Permission denied (publickey)`; the owner logs in on the serial console with the password.

### Implementation (2026-11-22)

Applied to the router by PR #61. The dry run checked the drop-in with the router's own
`sshd -t`; the first run changed the password and the drop-in and reloaded sshd, a second
run reported `changed=0`. Confirmed on 2026-11-22: `sshd -T` shows `permitrootlogin no`,
`passwordauthentication no` and `kbdinteractiveauthentication no`; `passwd -S debian` shows
`P`; an SSH login without a key is refused with `Permission denied (publickey)`; the owner
logged in as `debian` on the serial console with the password and logged out.

## More Information

* ADR-0026 (Ansible conventions), ADR-0028 (router and console path), ADR-0033 (VM
  conventions, cloud-init without secrets).
* `sshd_config(5)`: "For each keyword, the first obtained value will be used."
* Runbook: [lab-vms.md](../runbooks/lab-vms.md).
