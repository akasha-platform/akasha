# Bastion: toolchain and use

Design:
* [ADR-0040](../adr/0040-bastion-toolchain.md): toolchain, user, code;
* [ADR-0039](../adr/0039-openbao-on-core-bootstrap.md): host firewall defaults;
* [ADR-0047](../adr/0047-openbao-tls-and-network-access.md): the lab's root CA in the trust store.
* [ADR-0051](../adr/0051-kolla-toolchain.md): Kolla-Ansible's toolchain.

Managed by `infra/ansible/playbooks/bastion.yml`, through the roles `vm_firewall` (tag
`firewall`), `lab_trust` (tag `trust`) and `bastion_toolchain` (tag `toolchain`). OpenBao is at
`https://core.akasha.internal:8200` (runbook `core.md`, "Reach OpenBao over TLS").

## Use the bastion

```bash
ssh debian@10.10.0.10
sudo -iu akasha                # no password, no sudo
cd akasha/infra/ansible        # the repository (at the commit the last run printed), where ansible.cfg is
mise exec -- uv run --locked ansible --version
mise exec -- uv run --locked ansible-playbook playbooks/router.yml --syntax-check
```

`akasha` reaches the OpenStack nodes with a certificate from OpenBao: see the next section.

Kolla-Ansible ([ADR-0051](../adr/0051-kolla-toolchain.md)) runs from `infra/kolla`, so that
its own `ansible.cfg` and collections apply, never those of `infra/ansible`:

```bash
cd ~/akasha/infra/kolla
mise exec -- uv run --locked kolla-ansible --version
mise exec -- uv run --locked ansible all -m ping     # Kolla's inventory multinode; needs a certificate
```

Every `kolla-ansible` command reads `passwords.yml` from the configuration directory
(`--configdir .`), whatever `--passwords` says: see "Kolla's passwords" below.

## SSH to the OpenStack nodes

Design: [ADR-0050](../adr/0050-bastion-ssh-certificates-from-openbao.md). OpenBao's SSH CA signs
`akasha`'s key with the principal `os-node`, for 8 hours. The nodes trust the CA and let
`os-node` in as `debian` (role `ssh_user_ca`, playbook `openstack-nodes.yml`, tag `ssh_ca`). The bastion has the key, the
nodes' host keys and `akasha-ssh-cert` (role `bastion_ssh`, tag `ssh`). OpenBao must be
unsealed.

### Every working session

From the laptop, at the repository's root. The operator's password goes from the keyring to
the bastion on stdin:

```bash
mise exec -- uv run --locked --quiet python infra/opentofu/scripts/tofu_passphrase.py --service akasha-openbao --plain operator \
  | ssh -o BatchMode=yes -o LogLevel=error debian@10.10.0.10 'sudo -iu akasha akasha-ssh-cert'
# Key ID: "userpass-operator-node"
# Valid: from <now - 30 s> to <now + 8 h>
ssh debian@10.10.0.10
sudo -iu akasha
cd akasha/infra/ansible
mise exec -- uv run --locked ansible openstack_nodes -m ping
```

The certificate is `~/.ssh/id_ed25519-cert.pub`; ssh uses it on its own. When it has expired,
run the laptop command again. `akasha-ssh-cert` refuses a terminal on stdin, so the password is
never typed, or shown, on the bastion.

### Once: the operator, the CA and the roles

1. **The password.** In a desktop session on the laptop, generate it into the keyring. It is
   kept there only, never on paper (the owner's choice, ADR-0050 Implementation): `--init`
   shows it once, and that copy is not written down. If the keyring loses it, the admin sets a
   new one ("Change the operator's password").

   ```bash
   uv run --locked python infra/opentofu/scripts/tofu_passphrase.py --service akasha-openbao --init operator
   ```

2. **The user, then the stack.** At the repository's root, run the block "Every session" of
   runbook `openbao-pki.md` **only up to** `test -n "$VAULT_TOKEN"`: the tunnel and the admin's
   token, no plan yet. userpass needs a password to create a user, and OpenTofu writes only
   its token fields. So create the user first, with the password from the keyring on stdin and
   already bound to the bastion's address. `--plain` ends the password with a newline, which
   `bao write … password=-` would keep, so `tr` drops it:

   ```bash
   mise exec -- uv run --locked --quiet python infra/opentofu/scripts/tofu_passphrase.py --service akasha-openbao --plain operator \
     | tr -d '\n' | BAO_ADDR=http://127.0.0.1:8200 BAO_TOKEN="$VAULT_TOKEN" mise exec -- bao write auth/userpass/users/operator \
       password=- token_bound_cidrs=10.10.0.10
   cd infra/opentofu/live/openbao
   tofu plan -out=openbao.plan    # 5 to add: mount, CA, role, policy, operator's token fields
   tofu apply openbao.plan && tofu plan   # then: No changes
   ```

   Until the apply, `operator` holds only the `default` policy. Then
   make the off-AWS copy of the state (`openbao-pki.md`, "Off-AWS copy after every apply").

3. **The CA's public key in the repository**, checked against OpenBao (an unauthenticated
   endpoint):

   ```bash
   tofu output -raw ssh_user_ca_public_key > ../../../pki/ssh-user-ca.pub
   ssh-keygen -l -f ../../../pki/ssh-user-ca.pub
   curl -sS http://127.0.0.1:8200/v1/ssh-client-signer/public_key | ssh-keygen -l -f -   # same fingerprint
   cd ../../../..
   ```

   Commit it. End the session as in `openbao-pki.md` (revoke the token, close the tunnel).

4. **The nodes, then the bastion**, from `infra/ansible`, dry run first. `toolchain` installs
   the pinned `bao` CLI from `mise.lock` of the commit it checks out, `main` by default: merge
   the pull request that pins `bao` first, or pass `-e bastion_toolchain_commit=<branch>`.
   Then run the laptop command of "Every working session": it must print an 8-hour validity.

   ```bash
   uv run --locked ansible-playbook playbooks/openstack-nodes.yml --tags ssh_ca --check --diff
   uv run --locked ansible-playbook playbooks/openstack-nodes.yml --tags ssh_ca     # a second run: changed=0
   uv run --locked ansible-playbook playbooks/bastion.yml --tags toolchain,ssh --check --diff -e @~/akasha-private/lab_vms.yml
   uv run --locked ansible-playbook playbooks/bastion.yml --tags toolchain,ssh -e @~/akasha-private/lab_vms.yml
   ```

### Failure modes

* **Login refused.** OpenBao checks the password first, then the address:
  * `* invalid username or password`: a wrong password, or one that still ends with the
    newline of `--plain` (`bao login … password=-` keeps it; `akasha-ssh-cert` strips it,
    other commands need `tr -d '\n'`). Do not retry in a loop: failed logins count towards
    OpenBao's user lockout;
  * `* permission denied`: the right password, from another address than the bastion (the
    user is bound to 10.10.0.10).

  **`Vault is sealed`** (HTTP 503): unseal (runbook `core.md`).
* **`Permission denied (publickey)` from a node**:
  * the certificate expired: run the laptop command of "Every working session" again;
  * or the node does not trust the CA: `sudo sshd -T | grep -E 'trustedusercakeys|principalsfile'`
    and `cat /etc/ssh/akasha-principals/debian` (`os-node`) there, through the laptop's key.
* **`Host key verification failed`**: the node's host key changed (a rebuild). Verify it on the
  laptop first (runbook `lab-vms.md`), then run `bastion.yml --tags ssh` again.
* **A certificate must stop working now** (a stolen bastion). Certificates cannot be revoked,
  and root on the bastion may also have caught the operator's password at its last use. In
  this order:
  1. On each node, from the laptop: `sudo rm /etc/ssh/sshd_config.d/20-akasha-user-ca.conf &&
     sudo systemctl reload ssh`, then end the sessions that are already open:
     `sudo ss -K dst 10.10.0.10` (a reload keeps them).
  2. As admin through the tunnel, delete the user: `bao delete auth/userpass/users/operator`.
  3. Rebuild the bastion (runbook `opentofu-l0.md`, "Rebuilding one VM").
  4. Replace the CA: `tofu apply -replace=vault_ssh_secret_backend_ca.ssh_client_signer`,
     commit the new public key, run `--tags ssh_ca`.
  5. Give `operator` a new password in the keyring and create it again as in "Once".
  6. The operator's password also opened Kolla's passwords (ADR-0052): treat them as known.
     The operator could not change or destroy them, but could add names that did not exist
     yet. As admin, `bao kv metadata get kv/kolla/passwords/<name>` shows when each was
     created; look for one created after the init. Once OpenStack runs, change them
     (Kolla's password rotation, to be written in P2 step 8).
* **Change the operator's password**:
  * delete the keyring entry (service `akasha-openbao`, user `operator`; `--restore` and
    `--init` refuse an existing one), then `--init` again;
  * write it with `… --plain operator | tr -d '\n' | … bao write
    auth/userpass/users/operator/password password=-`, through the tunnel and the admin's
    token as in step 2.

## Kolla's passwords

Design: [ADR-0052](../adr/0052-kolla-passwords-in-openbao.md), and
[ADR-0053](../adr/0053-openstack-api-tls-and-vips.md) for the APIs' certificate. The passwords
live in OpenBao at `kv/kolla/passwords/<name>`, the certificate and its key at
`kv/kolla/tls/haproxy`. On the bastion they exist only while Kolla runs, on the tmpfs without
swap `/run/akasha-kolla` (role `bastion_kolla_passwords`, tag `kolla_passwords`):
* the copy `passwords.yml`, with `infra/kolla/passwords.yml` a link to it;
* `certificates/`, Kolla's `kolla_certificates_dir`: `haproxy.pem` and `haproxy-internal.pem`
  (the certificate, the intermediate and the key), `proxysql-cert.pem`, `proxysql-key.pem` and
  `proxysql-ca.pem` (MariaDB's TLS), and `ca/akasha-root-ca.crt`;
* Ansible's temporary files of the run (`infra/kolla/ansible.cfg`, `local_tmp`), which hold
  rendered configuration files with passwords.

The operator may read the passwords and add new ones, never change or delete one, and may only
read the certificate: changes, and the certificate's issuance, are the admin's, through the
laptop's tunnel (runbook `openbao-pki.md`). `akasha-kolla-passwords` takes the operator's password on
stdin from the laptop, like `akasha-ssh-cert`. OpenBao must be unsealed.

### Every Kolla run

From the laptop, at the repository's root (a certificate too, for the nodes: "Every working
session" above):

```bash
mise exec -- uv run --locked --quiet python infra/opentofu/scripts/tofu_passphrase.py --service akasha-openbao --plain operator \
  | ssh -o BatchMode=yes -o LogLevel=error debian@10.10.0.10 'sudo -iu akasha akasha-kolla-passwords read'
# WARNING: 'docker_registry_password' not found in Vault    (Kolla leaves it empty on purpose)
# read: 107 passwords; the APIs' certificate valid until <date> (<n> days)
# linked /home/akasha/akasha/infra/kolla/passwords.yml; ...
```

Then, as `akasha` on the bastion, always from `infra/kolla` (from elsewhere, or with
`ANSIBLE_CONFIG` set, Ansible's temporary files go to `~/.ansible/tmp` on the disk):

```bash
cd ~/akasha/infra/kolla
mise exec -- uv run --locked kolla-ansible <command> --configdir . -i multinode
akasha-kolla-passwords clean        # when done; a timer removes files older than 8 hours anyway
```

* `read` first removes any older copy and its link, then reports the name of a password that
  OpenBao lacks; it never leaves a copy behind on failure. A newer Kolla release that adds
  passwords needs `kolla-mergepwd` first; that mode is added with the first such bump.
* `read` writes the certificate files only after checking that the chain verifies against the
  lab's root (the copy of role `lab_trust`), the key matches, and the certificate holds both
  names and both VIP addresses. A failed check writes nothing, the passwords included. Within
  30 days of the expiry it prints `WARNING: the APIs' certificate expires on …`; below 7 days
  it refuses, which stops every Kolla run: renew it (runbook `openbao-pki.md`, "The OpenStack
  APIs' certificate").
* **Never run `kolla-ansible` with `--diff` (`-D`)**: Ansible prints the content of the files
  it copies or templates, the certificate's key and the passwords among them.
* `clean` empties the tmpfs and removes the link and the files `kolla-ansible post-deploy`
  writes (`clouds.yaml`, `*openrc*.sh`, with the admin password; git-ignored).
* **Never run `kolla-genpwd`, `kolla-readpwd` or `kolla-mergepwd` on
  `infra/kolla/passwords.yml`**: they replace the link with a plain file, and the 107 passwords
  land on the bastion's disk. `read` and `init` then refuse; `clean` removes it, but its blocks
  may remain.
* **Not yet**, because they write secrets outside the tmpfs:
  * `post-deploy`: the admin's credentials in `infra/kolla`; where they live is decided in
    P2 step 5;
  * `certificates`, never: its own test CA and private keys without a passphrase; the APIs'
    certificate comes from OpenBao's PKI (ADR-0053);
  * `octavia-certificates`: keys in `infra/kolla/octavia-certificates/` and
    `infra/kolla/config/octavia/`, and two passwords on `openssl`'s command line (P2 step 7).

### Once: generate the passwords

After the role ran and stack `openbao` has the mount `kv` and the policy `kolla-passwords`:

```bash
mise exec -- uv run --locked --quiet python infra/opentofu/scripts/tofu_passphrase.py --service akasha-openbao --plain operator \
  | ssh -o BatchMode=yes -o LogLevel=error debian@10.10.0.10 'sudo -iu akasha akasha-kolla-passwords init'
# WARNING: 'docker_registry_password' not found in Vault
# init: 106 passwords written to OpenBao and read back identical (1 left blank on purpose)
```

`init` refuses when OpenBao already holds any password: it never overwrites the passwords of a
running cloud. It generates them on the tmpfs with `kolla-genpwd`, then, in order:
1. checks that none is empty but the blank one;
2. writes them to OpenBao;
3. reads them back and compares;
4. removes the copy.

**A failed `init`** (network, token expiry, or "differ from those written") may leave part
of the passwords in OpenBao, and every later `init` refuses. Only **before any deployment**,
as admin through the tunnel (runbook `openbao-pki.md`, "Every session"):
1. delete them all, every version:

   ```bash
   export BAO_ADDR=http://127.0.0.1:8200 BAO_TOKEN="$VAULT_TOKEN"
   for n in $(mise exec -- bao kv list -format=json kv/kolla/passwords | jq -r '.[]'); do
     mise exec -- bao kv metadata delete "kv/kolla/passwords/$n"
   done
   mise exec -- bao kv list kv/kolla/passwords    # must say: No value found at kv/metadata/kolla/passwords
   unset BAO_TOKEN
   ```

2. run `init` again.

After a deployment, never do this: the cloud runs with those passwords.

### Failure modes

* **`… is not the tmpfs without swap`**: the mount is missing. Run `bastion.yml --tags
  kolla_passwords`, or, from the laptop,
  `ssh -o LogLevel=error debian@10.10.0.10 'sudo mount /run/akasha-kolla'` (it is in
  `/etc/fstab`).
* **`Unable to create local directories '/run/akasha-kolla/ansible-local'`**: the same
  missing mount, seen by Ansible from `infra/kolla`.
* **Login refused, `Vault is sealed`**: as for SSH certificates (above).
* **The APIs' certificate** (`read: …`, nothing written):
  * `no certificate at kv/kolla/tls/haproxy`: it was never issued, or was removed. Issue it
    (runbook `openbao-pki.md`, "The OpenStack APIs' certificate");
  * `expires on …, in less than 7 days`: issue a new one the same way, then `read` and
    `kolla-ansible reconfigure -t loadbalancer`;
  * `permission denied on kv/kolla/tls/haproxy`: stack `openbao` was not applied with the
    policy `kolla-tls` (runbook `openbao-pki.md`);
  * `does not verify for <name or address>`: a name, an address or the chain is wrong. Issue
    it again with the runbook's exact command;
  * `does not match its certificate`, or `does not hold a PEM …`: the secret was written by
    hand. Issue it again.
* **Change a password.** First read Kolla's
  [password rotation](https://docs.openstack.org/kolla-ansible/2026.1/admin/password-rotation.html)
  (`doc/source/admin/password-rotation.rst` at the pinned commit).
  * **Only the secrets in its `reconfigure` list** may simply be written and redeployed.
  * **Others need manual steps first**, or Kolla loses access: for example
    `database_password` (MariaDB's root), `nova_database_password`, `rabbitmq_password` and
    `kolla_ssh_key`.
  * **The write**, as admin through the tunnel:
    `BAO_ADDR=http://127.0.0.1:8200 BAO_TOKEN="$VAULT_TOKEN" mise exec -- bao kv put
    kv/kolla/passwords/<name> password=-`. The value comes on stdin, without a trailing
    newline (`bao` keeps it).
  * **An `*_ssh_key` entry** is a pair: write both fields,
    `… bao kv put kv/kolla/passwords/<name> private_key=@<file> public_key=@<file>`. A
    `password=` field would break `read`'s result.
  * **Old values:** KV v2 keeps the 10 last versions (`bao kv get -version=<n> …`); the daily
    snapshot (ADR-0049) keeps older ones.
* **At each bump of Kolla**: compare the new template with the old
  (`share/kolla-ansible/etc_examples/kolla/passwords.yml`) and `blank_keys` in
  `kolla_ansible/cmd/genpwd.py` with `BLANK` in the helper.

## Update the code

Run the playbook from the laptop. It checks out `main`, or the commit given with
`-e bastion_toolchain_commit=<sha>`, and prints the commit it checked out:

```bash
uv run ansible-playbook playbooks/bastion.yml --tags toolchain -e @~/akasha-private/lab_vms.yml
git ls-remote origin main      # on the laptop: the same SHA as the run printed
```

* **Local changes.** A modified tracked file stops the run (`force: false`): look at
  `git -C ~/akasha status` as `akasha`. Untracked files neither stop the checkout nor fail
  the checks.
* **Pins.** The run also installs whatever `mise.lock` and `uv.lock` changed.
* **Going back to an older commit.** Run the role of that commit, from a laptop checkout of
  it (`git worktree add --detach <dir> <sha>`, then the command above from `<dir>/infra/ansible`
  with `-e bastion_toolchain_commit=<sha>`). Today's role on a commit from before the group
  `kolla` (before ADR-0051) stops at `uv sync` ("Group `kolla` is not defined") and installs
  nothing; the older role removes Kolla. Tested in a container on 2026-11-28.
* **GitHub's rate limit.** `mise install` checks each tool's provenance through GitHub's API,
  unauthenticated. From the lab, the campus NAT shares its address, so the limit (60
  requests an hour) can be hit: the run stops, nothing half-installed is used. Wait and run it
  again.

## Bump the pinned mise

mise is not in Debian's archive. Its apt repository serves only the latest release, so it
cannot pin (ADR-0040). Renovate opens a pull request that changes only
`bastion_toolchain_mise_version` (ADR-0042). For a new version, on the laptop, in an empty
directory:

```bash
v=2026.11.12   # the new version, from Renovate's pull request
gh release view "v$v" -R jdx/mise --json publishedAt,isPrerelease   # at least 6 days old, not a pre-release
gh release download "v$v" -R jdx/mise -p SHASUMS256.asc -p "mise-v$v-linux-x64"
curl -fsSO https://mise.jdx.dev/gpg-key.pub
export GNUPGHOME=$(mktemp -d); gpg --import gpg-key.pub
gpg --fingerprint | grep -A1 pub   # 2485 3EC9 F655 CE80 B48E 6C3A 8B81 C9D1 7413 A06D
gpg --verify SHASUMS256.asc        # Good signature from "mise releases ..."
gpg --decrypt SHASUMS256.asc 2>/dev/null | grep "mise-v$v-linux-x64$"; sha256sum "mise-v$v-linux-x64"
```

* The fingerprint must match the one above and the one on
  https://mise.jdx.dev/installing-mise.html.
* Then change `bastion_toolchain_mise_version`, `bastion_toolchain_mise_sha256` and
  `bastion_toolchain_mise_published_at` in
  `infra/ansible/roles/bastion_toolchain/defaults/main.yml`: on Renovate's pull request, add
  a commit with the SHA-256 and the publication time.
* Run `bastion.yml --tags toolchain`.
* The role reads mise's progress line to report a change (`installed 0 tools`): check that
  this wording is unchanged in the new version.

## Roll back

```bash
sudo pkill -u akasha; sudo userdel -r akasha
sudo rm -rf /usr/local/bin/mise /etc/mise
```

`git` stays installed. The host firewall rolls back as on `core` (runbook `core.md`, "Host
firewall").

SSH to the nodes (ADR-0050): `userdel -r` removes `akasha`'s key and known hosts; also run
`sudo rm /usr/local/bin/akasha-ssh-cert`. On each node, through the laptop's key:
`sudo rm -r /etc/ssh/sshd_config.d/20-akasha-user-ca.conf /etc/ssh/akasha-user-ca.pub
/etc/ssh/akasha-principals && sudo systemctl reload ssh`. In OpenBao:
* remove `ssh.tf` and its output, then plan and apply;
* delete the user: `bao delete auth/userpass/users/operator`, as admin. Or rebuild the bastion (runbook `opentofu-l0.md`, "Rebuilding one VM"): it keeps no
data of its own.
