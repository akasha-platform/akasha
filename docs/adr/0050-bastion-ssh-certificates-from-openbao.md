---
status: accepted
date: 2026-11-27
decision-makers: dhuy21
---

# SSH from the bastion to the OpenStack nodes with short-lived certificates from OpenBao

## Context and Problem Statement

Kolla-Ansible runs on the bastion (ADR-0040) and needs root on the three OpenStack nodes
(ADR-0041). It reaches them over SSH as a user with passwordless sudo. Today only the owner's
laptop key opens the lab's VMs (ADR-0035), and the bastion holds no credential: ADR-0040
deferred how it authenticates to P2.

Kolla's own way (VERIFIED, Kolla-Ansible 2026.1 docs, "bootstrap-servers"):
* the first run uses an existing sudo user;
* it can create a user `kolla` with passwordless sudo and authorise `kolla_ssh_key`, a key pair
  kept in `passwords.yml`.

So whatever the choice, the bastion first needs a way into `debian`.

Facts checked on 2026-11-27, in Debian 13 containers with OpenBao 2.7.3 and Debian's OpenSSH:
* **Signing.**
  * The `ssh` secrets engine generates an ed25519 CA key inside OpenBao.
  * A role limited to the principal `os-node`, ed25519 keys, `permit-pty` and 8 hours signs a
    certificate that sshd accepts for `debian` through `TrustedUserCAKeys` and an
    `AuthorizedPrincipalsFile` that lists `os-node` for `debian`.
  * The certificate is valid from 30 s before signing (`not_before_duration`).
* **Refusals.** OpenBao refuses:
  * a certificate with another principal (`root`, `debian`);
  * an RSA key;
  * a TTL above 8 h;
  * the extension `permit-port-forwarding`.

  sshd refuses the certificate for a user without a principals file (`root`, `other`).
* **authorized_keys still works** next to the CA: the owner's key keeps opening the nodes.
* **Login and token limits.**
  * A userpass login from an address outside `token_bound_cidrs` is refused ("permission
    denied").
  * The operator's token may not list mounts or read the CA's configuration.
  * OpenBao stores a bound `/32` without its prefix (`127.0.0.1/32` reads back `127.0.0.1`),
    so the configuration writes the bare address.
* **The `hashicorp/vault` provider 5.13.0.**
  * `vault_ssh_secret_backend_ca` and `vault_ssh_secret_backend_role` apply against OpenBao, and
    a second plan is empty.
  * The state holds the CA's public key only (`private_key` is null).
* **Ansible.** The two roles below ran three times against containers (dry run, run, run): the
  last run reported `changed=0`.
* **Audit trail.** sshd logged `ED25519-CERT … ID userpass-operator-node (serial …) CA
  ED25519 …`.
* **The helper's token** was gone afterwards.

## Decision Drivers

* No long-lived credential on the bastion that is root on the nodes.
* Fail safe: a broken CA must not lock the owner out of a node.
* Every login traceable to who asked for it.
* Keep the pieces the lab already has: OpenBao, the OpenTofu stack `openbao`, pinned tools.

## Considered Options

* **Credential:**
  * **short-lived certificates signed by OpenBao's SSH CA**;
  * a static key of the bastion;
  * agent forwarding from the laptop.
* **The operator's login to OpenBao from the bastion:**
  * **a new userpass user `operator` with a password**;
  * an AppRole of the bastion;
  * signing on `core` as `admin` and copying the certificate.
* **Certificate lifetime:** **8 hours**; 2 hours; 1 hour.
* **The nodes' host keys on the bastion:**
  * **copied from the laptop's `known_hosts`**;
  * host certificates signed by OpenBao.
* **The `bao` CLI on the bastion:**
  * **pinned in `mise.toml`**;
  * none, with a curl-only helper.
* **The certificate's principal** (raised by the independent review):
  * **a name per group of VMs, `os-node`, mapped to `debian` on the nodes by
    `AuthorizedPrincipalsFile`**;
  * the Unix user name `debian`, which every VM that ever trusts the CA would accept.
* **Scope of the step:**
  * **SSH only, the nodes' firewall after the deployment**;
  * also turn LLMNR off now.

## Decision Outcome

Chosen by the owner on 2026-11-27 (the options in bold).

* **OpenBao** (stack `openbao`, `ssh.tf`):
  * the mount `ssh-client-signer`;
  * an ed25519 CA generated inside OpenBao;
  * the role `node`:
    * principal `os-node` only, ed25519 keys only, `permit-pty` only;
    * 8 hours. `allowed_critical_options` is empty, which OpenBao reads as "any". OpenSSH's
      critical options only restrict a certificate (`force-command`, `source-address`,
      `verify-required`), so that grants nothing;
    * key ID `{{token_display_name}}-{{role_name}}`.

  The policy `operator` may only sign with that role. The userpass user `operator` gets tokens
  of 15 minutes, bound to `10.10.0.10`. As for `admin`, the user and its password are created
  by hand and OpenTofu writes only the token fields, so the password never reaches the state.
* **The password** is generated into the laptop's keyring (service `akasha-openbao`, user
  `operator`) and copied on paper. It reaches the bastion on stdin, from the laptop, never on
  a screen or a command line.
* **The nodes** (role `ssh_user_ca`, playbook `openstack-nodes.yml`, tag `ssh_ca`):
  * the CA's public key, committed as `infra/pki/ssh-user-ca.pub`, goes to
    `/etc/ssh/akasha-user-ca.pub`;
  * the drop-in `20-akasha-user-ca.conf` sets `TrustedUserCAKeys` and
    `AuthorizedPrincipalsFile /etc/ssh/akasha-principals/%u`;
  * `/etc/ssh/akasha-principals/debian` (root, 0644) lists `os-node`. Another user has no file
    and accepts no certificate;
  * sshd checks it before it replaces anything, also in a dry run.

  A changed CA therefore needs a pull request.
* **The bastion** (role `bastion_ssh`, playbook `bastion.yml`, tag `ssh`):
  * `akasha` gets an ed25519 key, which opens nothing by itself;
  * the nodes' host keys are copied from the laptop's `known_hosts`, where each was compared
    with the VM's serial console;
  * `akasha-ssh-cert` reads the password on stdin, logs in, has the key signed, writes
    `~/.ssh/id_ed25519-cert.pub` (which ssh picks up on its own), revokes its token and prints
    the key ID and validity.

  The `bao` CLI 2.7.3, the same version as `core`'s server, is pinned in `mise.toml` with its
  checksum and cosign provenance.

### Consequences

* Good, because nothing on the bastion opens a node for more than 8 hours: an old disk image
  or backup of the bastion is useless.
* Good, because every login carries a key ID and a serial in the node's journal, and every
  signature is in OpenBao's audit log.
* Good, because the owner's key and the serial console still open the nodes if OpenBao, the CA
  or the bastion fails.
* Good, because the same identity can be given the read access of step 3 (Kolla's passwords in
  OpenBao KV v2).
* Bad, because a certificate cannot be revoked before it expires (no `RevokedKeys` list). In an
  emergency, remove the drop-in from the nodes.
* Bad, because no new certificate can be signed while OpenBao is sealed (after every reboot of
  `core`), so Kolla cannot run then.
* Bad, because the password is a long-lived secret. Its reach is narrow: it works only from the
  bastion's address and only signs `os-node` certificates. But whoever controls the bastion
  catches it at its next use. That can be root, or code running as `akasha`, which owns the
  `bao` binary and the repository. From then on they can sign new certificates every 8 hours
  until the password changes. The response is in the runbook: remove the CA from the nodes,
  end the open sessions, delete `operator`, rebuild the bastion, replace the CA.
* Bad, because the address binding (`token_bound_cidrs`, `core`'s firewall) trusts
  `br-mgmt`: root on another VM of that bridge could take 10.10.0.10 (ARP spoofing). libvirt
  filters such as `clean-traffic` are not used. Accepted for the lab; the password is still
  needed.
* Bad, because a node whose host key changes (a rebuild) must first be verified on the laptop,
  then the bastion role run again.
* Neutral: `bao` (the CLI) and `openbao` (the server, role `openbao`) are pinned in two places.
  They are bumped together.

### Confirmation

Before:
* the OpenTofu plan adds the five resources;
* a second plan is empty;
* the CA's public key matches OpenBao's `ssh-client-signer/public_key`.

On the nodes, a second run of `ssh_user_ca` reports `changed=0` and `sshd -T` names the CA
and the principals' files.
From the bastion, as `akasha`:
* `akasha-ssh-cert` prints an 8-hour validity;
* `ssh debian@<node>` and `ansible openstack_nodes -m ping` succeed;
* a node's journal shows the certificate's key ID.

These are refused:
* a certificate with the principal `debian` or `root`;
* the certificate for `root`;
* a login as `operator` from the laptop through the tunnel.

The laptop's key still opens every node.

### Implementation (2026-11-28)

Code from PR #87; applied on 2026-11-27 and 2026-11-28.

* **The password is in the laptop's keyring only, with no paper copy** (the owner's choice,
  2026-11-27, which replaces "copied on paper" above). If the keyring loses it, the admin sets
  a new one (runbook). Nothing else depends on it: the owner's key and the serial console still
  open the nodes.
* **OpenBao.** `operator` was created by hand, bound to `10.10.0.10` from the start. The plan
  added the five resources and a second plan was empty. The CA's public key
  (`SHA256:uj+2k/wrD4GQWcKoIZB9umz8mKyCIq48viN3xUnkICI`) matches OpenBao's
  `ssh-client-signer/public_key` and is committed as `infra/pki/ssh-user-ca.pub`.
* **The nodes.** `ssh_user_ca` ran on `os-cmp02` first, then on the other two. A second run on
  all three reported `changed=0`.
* **The bastion.** `bastion.yml --tags toolchain,ssh` checked out `main` (the same commit as
  GitHub) and installed `bao` 2.7.3. `akasha`'s key is
  `SHA256:iyXOuub+7uIDRW0bYU97LRjI8QgFxuctZCS6Een9jO0`.
* **The checks of Confirmation all passed on the lab:**
  * `akasha-ssh-cert` printed the key ID `userpass-operator-node` and 8 hours plus 30 s of
    validity;
  * as `akasha`, `ssh debian@` each node, `ansible -m ping` and `ansible -b -a id`
    (`uid=0(root)`) succeeded;
  * each node's journal logged `ED25519-CERT … ID userpass-operator-node (serial …) CA ED25519
    SHA256:uj+2k…`;
  * the operator's token read back as `[default operator]`, 900 s, bound to `10.10.0.10`;
  * refused:
    * `ssh root@` with the certificate;
    * the principals `debian` and `root`;
    * a TTL of 9 h ("larger than maximum allowed");
    * `permit-port-forwarding`;
    * an RSA key;
    * `secrets list` and reading the CA's configuration ("permission denied");
    * a login as `operator` from the laptop through the tunnel ("permission denied");
  * no `authorized_keys` on the nodes lists `akasha`'s key, and once the certificate was
    deleted, that key alone was refused.
* **Login order (VERIFIED, OpenBao's `builtin/credential/userpass/path_login.go`, and on the
  lab).** userpass checks the password before the bound address:
  * a wrong password gets "invalid username or password" from any address;
  * only the right password from another address gets "permission denied".

  So the binding does not stop guessing from elsewhere: the random password and OpenBao's
  user lockout do. The first laptop test sent the password with `--plain`'s newline and was
  refused for the wrong reason ("invalid username or password"). It was run again through
  `tr -d '\n'`. The runbook's failure modes now tell the two messages apart.
* **The certificate of the tests was deleted** from the bastion afterwards; the next session
  asks for a new one.

## More Information

* The independent review (2026-11-27) found one blocker, fixed before anything ran: `--plain`
  ends the password with a newline, which `bao write … password=-` would have stored, so no
  login would ever match. The runbook strips it with `tr -d '\n'`, and the container test
  creates the user that way. Its other findings, also fixed:
  * the helper refuses a terminal on stdin, so the password is never typed on the bastion;
  * the runbook stops the token block before `openbao-pki.md`'s apply;
  * it says to merge before the bastion's run;
  * it gives a complete response to a stolen bastion;
  * the principal `os-node`;
  * the comment on critical options;
  * the known_hosts markers.

* OpenBao, "Signed SSH certificates":
  https://openbao.org/docs/secrets/ssh/signed-ssh-certificates/
* Kolla-Ansible 2026.1, "Bootstrapping servers":
  https://docs.openstack.org/kolla-ansible/2026.1/reference/deployment-and-bootstrapping/bootstrap-servers.html
* `sshd_config(5)`, `TrustedUserCAKeys`; `ssh-keygen(1)`, "Certificates".
* ADR-0011 (OpenBao as the SSH CA), ADR-0035 (access to the VMs), ADR-0040 (the bastion),
  ADR-0045 (the admin), ADR-0047 (OpenBao's TLS listener).
* Runbook: [bastion.md](../runbooks/bastion.md), "SSH to the OpenStack nodes".
