# Bastion: toolchain and use

Design:
* [ADR-0040](../adr/0040-bastion-toolchain.md): toolchain, user, code;
* [ADR-0039](../adr/0039-openbao-on-core-bootstrap.md): host firewall defaults.

Managed by `infra/ansible/playbooks/bastion.yml`, through the roles `vm_firewall` (tag
`firewall`) and `bastion_toolchain` (tag `toolchain`).

## Use the bastion

```bash
ssh debian@10.10.0.10
sudo -iu akasha                # no password, no sudo
cd akasha/infra/ansible        # the repository (at the commit the last run printed), where ansible.cfg is
mise exec -- uv run --locked ansible --version
mise exec -- uv run --locked ansible-playbook playbooks/router.yml --syntax-check
```

`akasha` cannot SSH to the other VMs yet: how the bastion authenticates to them is decided in
P2 (ADR-0040).

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
cannot pin (ADR-0040; open question B16). Keep the same version as the laptop. For a new
version, on the laptop, in an empty directory:

```bash
v=2026.11.12   # the new version, the laptop's
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
  `infra/ansible/roles/bastion_toolchain/defaults/main.yml` (pull request).
* Run `bastion.yml --tags toolchain`.
* The role reads mise's progress line to report a change (`installed 0 tools`): check that
  this wording is unchanged in the new version.

## Roll back

```bash
sudo pkill -u akasha; sudo userdel -r akasha
sudo rm -rf /usr/local/bin/mise /etc/mise
```

`git` stays installed. The host firewall rolls back as on `core` (runbook `core.md`, "Host
firewall"). Or rebuild the bastion (runbook `opentofu-l0.md`, "Rebuilding one VM"): it keeps no
data of its own.
