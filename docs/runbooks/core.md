# core: OpenBao and its host firewall

Design:
* [ADR-0011](../adr/0011-openbao-secrets-and-pki.md): OpenBao, Shamir;
* [ADR-0038](../adr/0038-data-disks-outlive-vms.md): the data disk on `/srv`;
* [ADR-0039](../adr/0039-openbao-on-core-bootstrap.md): pinned package, localhost until
  step 7, host firewall.

Managed by `infra/ansible/playbooks/core.yml`, through the roles `vm_firewall` (tag `firewall`)
and `openbao` (tag `openbao`). Commands run on `core` (`ssh debian@10.10.0.12`) unless stated
otherwise.

## Check

```bash
systemctl is-active openbao nftables             # active active
BAO_ADDR=http://127.0.0.1:8200 bao status        # Initialized false, Sealed true, Storage Type raft (until step 7)
sudo ss -lntp | grep bao                         # 127.0.0.1:8200 only (8201 too once unsealed)
findmnt /srv; sudo ls -ld /srv/openbao/raft      # ext4 akasha-data; openbao 0700
sudo nft list ruleset | head -20                 # table inet akasha, input policy drop
```

`bao status` exits with 2 while OpenBao is sealed: that is not an error.

## OpenBao does not start

- **Symptom:** `systemctl status openbao` shows failed or inactive.
- **Diagnosis:**
  - `journalctl -u openbao -n 50`.
  - "Dependency failed" or a mount error: `/srv` is not mounted (data disk missing or not
    yet mounted). OpenBao refuses to run without it by design: see `lab-vms.md`, "Data disk
    of core".
  - A configuration error: the role wrote `/etc/openbao/openbao.hcl`, so fix the role, not
    the file.
- **Mitigation:** mount the disk (`sudo mount /srv`) or fix the role and run
  `core.yml --tags openbao`.

## Restart an initialised OpenBao (from step 7 on)

A restart **seals** OpenBao, and nothing that depends on it works until it is unsealed with
the Shamir shares (ADR-0011). The role never restarts an initialised OpenBao: when its
configuration changed, the run stops with "restart it by hand and unseal it". Then:

```bash
sudo systemctl restart openbao
BAO_ADDR=http://127.0.0.1:8200 bao operator unseal    # once per share, up to the threshold
```

## Bump the pinned OpenBao version

OpenBao is not in Debian's archive: unattended upgrades never patch it (open question B16).
For a new release, on the laptop, in an empty directory:

```bash
v=2.7.4   # the new version
gh release view "v$v" -R openbao/openbao --json publishedAt,isPrerelease   # at least 6 days old, not a pre-release
gh release download "v$v" -R openbao/openbao -p checksums.txt -p checksums.txt.gpgsig -p openbao-gpg-pub-20240618.asc
export GNUPGHOME=$(mktemp -d); gpg --import openbao-gpg-pub-20240618.asc
gpg --fingerprint | grep -A1 pub     # 66D1 5FDD 8728 7219 C8E1 5478 D200 CD70 2853 E6D0
gpg --verify checksums.txt.gpgsig checksums.txt                   # Good signature from "OpenBao ..."
grep "openbao_${v}_linux_amd64.deb$" checksums.txt               # the new SHA-256
```

* **The fingerprint** must match both the one above and the one on
  https://openbao.org/docs/install/ ("Primary key fingerprint"), a channel other than GitHub.
  A new key file name or fingerprint is a finding: stop.
* **Sigstore**: the install page also shows `cosign verify-blob` for `checksums.txt` against the
  release workflow's identity. cosign is not in the pinned toolchain yet (B16): until it is,
  only the GPG signature is checked.
* **Read the release and upgrade notes.**
* **Change** `openbao_version`, `openbao_deb_sha256` and `openbao_published_at` in
  `infra/ansible/roles/openbao/defaults/main.yml` (pull request).
* **From step 7 on**, take a snapshot first:
  `BAO_ADDR=... bao operator raft snapshot save /srv/openbao/pre-upgrade.snap`.
* **Run** `core.yml --tags openbao`. The role installs the new package, but it does not
  restart an initialised OpenBao: it stops with "restart it by hand and unseal it". Then
  restart, unseal (above), and run the role again: it checks that the **running server**
  reports the new version.

## Host firewall

The same commit-confirmed loading as the router's (runbook `router.md`, "Firewall and
forwarding"). Input accepts:
* SSH from the bastion (`10.10.0.10`) and the tailnet (`10.255.255.1`) only;
* ping from `br-mgmt` and the tailnet;
* nothing else.

Drops are logged:

```bash
sudo journalctl -k -g 'akasha drop' -n 20
```

Test from the bastion: `nc -zv -w3 10.10.0.12 8200` must **time out** (dropped by the
firewall), not answer "connection refused". Then the drop shows in the log above.

An nftables package upgrade (unattended upgrades) restarts `nftables.service`. Its stop
flushes the rules, so `core` accepts everything for a moment until the rules load again.

Locked out: on the serial console (runbook `lab-vms.md`), `sudo nft flush ruleset`, then fix
the role and run it again.

## Roll back

**Before step 7 only**: once OpenBao is initialised, `/srv/openbao` holds every secret of the
lab. Never delete it without a verified backup.

```bash
sudo systemctl disable --now openbao && sudo apt purge openbao
sudo rm -rf /srv/openbao /opt/openbao /etc/systemd/system/openbao.service.d /var/cache/akasha/openbao_*.deb
sudo systemctl daemon-reload
sudo systemctl disable --now nftables     # stopping it flushes the rules
```

Or rebuild `core` (runbook `opentofu-l0.md`, "Rebuilding one VM"): the data disk is kept.
