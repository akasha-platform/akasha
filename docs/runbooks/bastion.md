# Bastion: toolchain and use

Design:
* [ADR-0040](../adr/0040-bastion-toolchain.md): toolchain, user, code;
* [ADR-0039](../adr/0039-openbao-on-core-bootstrap.md): host firewall defaults;
* [ADR-0047](../adr/0047-openbao-tls-and-network-access.md): the lab's root CA in the trust store.

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

## SSH to the OpenStack nodes

Design: [ADR-0050](../adr/0050-bastion-ssh-certificates-from-openbao.md). OpenBao's SSH CA signs
`akasha`'s key for the user `debian` of the nodes, for 8 hours. The nodes trust the CA (role
`ssh_user_ca`, playbook `openstack-nodes.yml`, tag `ssh_ca`). The bastion has the key, the
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
run `akasha-ssh-cert` again.

### Once: the operator, the CA and the roles

1. **The password.** In a desktop session on the laptop, generate it into the keyring and copy
   it on paper (groups of 8), then check the paper:

   ```bash
   uv run --locked python infra/opentofu/scripts/tofu_passphrase.py --service akasha-openbao --init operator
   uv run --locked python infra/opentofu/scripts/tofu_passphrase.py --service akasha-openbao --verify operator
   ```

2. **The user, then the stack.** Open the tunnel and get the admin's token as in runbook
   `openbao-pki.md` ("Apply"). userpass needs a password to create a user, and OpenTofu writes
   only its token fields. So create the user first, with the password from the keyring on
   stdin:

   ```bash
   mise exec -- uv run --locked --quiet python infra/opentofu/scripts/tofu_passphrase.py --service akasha-openbao --plain operator \
     | BAO_ADDR=http://127.0.0.1:8200 BAO_TOKEN="$VAULT_TOKEN" mise exec -- bao write auth/userpass/users/operator password=-
   cd infra/opentofu/live/openbao
   tofu plan -out=openbao.plan    # 5 to add: mount, CA, role, policy, operator's token fields
   tofu apply openbao.plan && tofu plan   # then: No changes
   ```

   Until the apply, `operator` holds only the `default` policy and no address binding.

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
   the pinned `bao` CLI from `mise.lock`:

   ```bash
   uv run --locked ansible-playbook playbooks/openstack-nodes.yml --tags ssh_ca --check --diff
   uv run --locked ansible-playbook playbooks/openstack-nodes.yml --tags ssh_ca     # a second run: changed=0
   uv run --locked ansible-playbook playbooks/bastion.yml --tags toolchain,ssh --check --diff -e @~/akasha-private/lab_vms.yml
   uv run --locked ansible-playbook playbooks/bastion.yml --tags toolchain,ssh -e @~/akasha-private/lab_vms.yml
   ```

### Failure modes

* **`* permission denied` at login**: wrong password, or not from the bastion (the user is
  bound to 10.10.0.10). **`Vault is sealed`** (HTTP 503): unseal (runbook `core.md`).
* **`Permission denied (publickey)` from a node**:
  * the certificate expired: run `akasha-ssh-cert`;
  * or the node does not trust the CA: `sudo sshd -T | grep trustedusercakeys` there, through
    the laptop's key.
* **`Host key verification failed`**: the node's host key changed (a rebuild). Verify it on the
  laptop first (runbook `lab-vms.md`), then run `bastion.yml --tags ssh` again.
* **A certificate must stop working now** (a stolen bastion): certificates cannot be revoked.
  From the laptop, on each node: `sudo rm /etc/ssh/sshd_config.d/20-akasha-user-ca.conf && sudo
  systemctl reload ssh`. Then replace the CA:
  * `tofu apply -replace=vault_ssh_secret_backend_ca.ssh_client_signer`;
  * commit the new public key;
  * run `--tags ssh_ca`.
* **Change the operator's password**:
  * `--restore` a new value into the keyring (or delete the entry and `--init` again);
  * write it with `bao write auth/userpass/users/operator/password password=-`, through the
    tunnel and the admin's token as in step 2;
  * update the paper.

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
`sudo rm /etc/ssh/sshd_config.d/20-akasha-user-ca.conf /etc/ssh/akasha-user-ca.pub && sudo
systemctl reload ssh`. In OpenBao:
* remove `ssh.tf` and its output, then plan and apply;
* delete the user: `bao delete auth/userpass/users/operator`, as admin. Or rebuild the bastion (runbook `opentofu-l0.md`, "Rebuilding one VM"): it keeps no
data of its own.
