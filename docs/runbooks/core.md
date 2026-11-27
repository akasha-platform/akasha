# core: OpenBao and its host firewall

Design:
* [ADR-0011](../adr/0011-openbao-secrets-and-pki.md): OpenBao, Shamir;
* [ADR-0038](../adr/0038-data-disks-outlive-vms.md): the data disk on `/srv`;
* [ADR-0039](../adr/0039-openbao-on-core-bootstrap.md): pinned package, localhost until
  step 7, host firewall;
* [ADR-0045](../adr/0045-openbao-initialisation-and-administration.md): initialisation, unseal
  shares, audit log, administrator;
* [ADR-0047](../adr/0047-openbao-tls-and-network-access.md): TLS listener, its certificate,
  firewall, trust store, the admin bound to loopback;
* [ADR-0049](../adr/0049-openbao-daily-backup.md): the daily off-site backup (runbook
  `backups.md`, section "core").

Managed by `infra/ansible/playbooks/core.yml`, through the roles `vm_firewall` (tag `firewall`)
and `openbao` (tag `openbao`). Commands run on `core` (`ssh debian@10.10.0.12`) unless stated
otherwise.

## Check

```bash
systemctl is-active openbao nftables             # active active
BAO_ADDR=http://127.0.0.1:8200 bao status        # Initialized true, Sealed false (true after a reboot), Total Shares 3, Threshold 2
sudo ls -l /srv/openbao/audit                    # audit.log, openbao, 0600; rotated files .1, .2.gz, ...
sudo ss -lntp | grep bao                         # 10.10.0.12:8200 and loopback 8200-8202 only
sudo ls -l /srv/openbao/tls                      # openbao.crt, openbao.key (root:openbao 0640)
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

## Secrets on the laptop

In `~/akasha-private/openbao/` (ADR-0045), read-only (`chmod 400`). Never commit them, never
print them. The commands below run **on the laptop**, in a shell where these are set, from the
repository (mise finds age there):

```bash
cd ~/Documents/dev/Projets/akasha && P=~/akasha-private/openbao && AGE=$(mise which age) \
  && KEYGEN=$(dirname "$AGE")/age-keygen && set -o pipefail
ssh -o BatchMode=yes debian@10.10.0.12 true && echo "ssh ok"   # else ssh-add first: only age may prompt
```

Each decryption asks for the passphrase of ADR-0044 once.

| File | Content |
|---|---|
| `identity.age` | the age identity, encrypted with the passphrase |
| `recipient.txt` | its public key |
| `share-1.age`, `share-2.age`, `share-3.age` | the three unseal shares (any two unseal) |
| `admin-password.age` | the password of the userpass user `admin` |

## Unseal (after each reboot or restart of core)

A restart **seals** OpenBao, and nothing that depends on it works until it is unsealed
(ADR-0011). Two shares, each through a pipe, never on a screen:

```bash
"$AGE" -d -i $P/identity.age $P/share-1.age | ssh -o BatchMode=yes debian@10.10.0.12 akasha-bao-unseal   # sealed=true progress=1/2
"$AGE" -d -i $P/identity.age $P/share-2.age | ssh -o BatchMode=yes debian@10.10.0.12 akasha-bao-unseal   # sealed=false
```

Any two shares work. A share given to an unsealed OpenBao only prints `sealed=false`.
"unseal refused" names the reason, such as a wrong share. `bao operator unseal -reset` on `core`
restarts a half-done unseal.

## Restart an initialised OpenBao

The role never restarts an initialised OpenBao: when its configuration changed, the run stops
with "restart it by hand and unseal it". **Do it the same day**: the new file is already on
disk, and logrotate's daily reload (SIGHUP) would apply its audit stanza without the restart
(ADR-0045). Then `sudo systemctl restart openbao` on `core`, unseal (above), and run the role
again.

## Log in as admin

```bash
"$AGE" -d -i $P/identity.age $P/admin-password.age \
  | ssh -o BatchMode=yes debian@10.10.0.12 'BAO_ADDR=http://127.0.0.1:8200 bao login -method=userpass username=admin password=- >/dev/null && echo logged-in'
ssh debian@10.10.0.12
export BAO_ADDR=http://127.0.0.1:8200
bao token lookup | grep -E 'policies|ttl'          # [admin default], about 1h
# ... the work ...
bao token revoke -self                               # the token is kept in ~/.vault-token until then
```

A token lives 1 h, and 4 h at most with renewals. The admin logs in, and its tokens work, from
127.0.0.1 only (`token_bound_cidrs`, set by the stack `openbao`): on `core` or through
OpenTofu's tunnel, never through the TLS listener. A root token is never kept: if one is needed,
`bao operator generate-root` makes it from two shares; revoke it after use.

## OpenBao's certificate (issue or renew)

`/srv/openbao/tls/openbao.crt` (leaf and intermediate) and `openbao.key` (root:openbao 0640), on
the data disk, one year, from the PKI role `server` (runbook `openbao-pki.md`). The role fails
when fewer than 30 days remain. Issue or renew from the laptop: the admin logs in on `core`,
its token goes straight into the helper, which reloads OpenBao (SIGHUP: no seal, no restart)
and revokes the token:

```bash
"$AGE" -d -i $P/identity.age $P/admin-password.age | ssh -o BatchMode=yes debian@10.10.0.12 \
  'BAO_ADDR=http://127.0.0.1:8200 bao login -method=userpass -token-only -no-store username=admin password=- | sudo akasha-bao-tls'
```

It prints the new certificate's subject, end date, fingerprint and names. `akasha-bao-tls`
refuses an empty token and stops when the chain does not verify against the system trust store
(role `lab_trust`) or the key does not match.

**Without a certificate** (the first time, or a new data disk), the role configures loopback
only, OpenBao keeps running, and the run ends with "openbao.crt is missing". Then: issue the
certificate (above), run `core.yml --tags openbao` again (it writes the TLS listener and stops
with "restart it by hand"), restart OpenBao and unseal it, run the role once more. A rebuild of
`core` that keeps the data disk keeps the certificate: nothing to do.

## Reach OpenBao over TLS

`https://core.akasha.internal:8200` (or `https://10.10.0.12:8200`), TLS 1.3 only. The firewall
of `core` accepts port 8200 from the bastion only (`host_vars/core.yml`). Not from the tailnet:
`10.255.255.1` is also every process of `insa`, and anyone reaching the userpass login can lock
the admin out with wrong passwords (ADR-0047). The laptop uses SSH to `core` (loopback) or
checks through the bastion, which trusts the root (role `lab_trust`):

```bash
ssh debian@10.10.0.10 'curl -sS https://core.akasha.internal:8200/v1/sys/seal-status' | jq -c '{sealed, version}'
```

Python `requests`/`httpx` in a virtual environment use certifi, not the system store: set
`REQUESTS_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt` (Kolla, P2). Adding a client: `lab_trust`
on it, and its address in `vm_firewall_tcp_services` of `core`.

## Admin locked out (break-glass)

The admin is locked for 15 minutes after 5 wrong passwords (per user, from any source): wait.
If its password or binding is lost, make a root token from two shares, on `core`'s loopback,
where the unauthenticated `generate-root` endpoints are enabled (ADR-0047):

```bash
ssh -t debian@10.10.0.12
export BAO_ADDR=http://127.0.0.1:8200
otp=$(bao operator generate-root -generate-otp); bao operator generate-root -init -otp="$otp"
bao operator generate-root                # once per share, at the prompt (two shares)
bao operator generate-root -decode=<encoded token> -otp="$otp"   # the root token
# fix (for example `bao write auth/userpass/users/admin password=-`), then revoke it:
BAO_TOKEN=<root token> bao token revoke -self
```

The prompt hides what is typed, but the share must be read from somewhere: decrypt it in
another terminal (`"$AGE" -d -i $P/identity.age $P/share-1.age`), type it, then
`clear; printf '\e[3J'`. This is the one procedure where a share shows on a screen; it is
rare, and it was not rehearsed (only the loopback endpoint's answer was checked, ADR-0047).
Record the event in an ADR update.

## Audit log

`/srv/openbao/audit/audit.log` on the data disk, mode 0600, secrets HMAC'd. logrotate rotates
it daily and keeps 30 days; `systemctl reload openbao` makes OpenBao reopen the file (it stays
unsealed). OpenBao answers **no request** it cannot audit: when requests fail or hang, check
the disk first.

```bash
df -h /srv; sudo tail -n 2 /srv/openbao/audit/audit.log | python3 -m json.tool | head -20
```

## Initialise OpenBao (done once, step 7c-2)

On the laptop, with the variables above, swap off (`sudo swapoff -a`), one command at a time.
Each command checks its inputs and refuses to overwrite a file. Until a secret is stored, a
failed initialisation is undone by wiping the data on `core` (`sudo systemctl stop openbao &&
sudo rm -rf /srv/openbao/raft /srv/openbao/audit`), running `core.yml --tags openbao`, and
deleting the laptop's files.

```bash
# 1. The age identity, protected by the passphrase; its public key
umask 077; mkdir -p $P && test ! -e $P/identity.age && "$KEYGEN" | tee >("$KEYGEN" -y > $P/recipient.txt) \
  | "$AGE" -p -o $P/identity.age && chmod 400 $P/identity.age
chmod 400 $P/recipient.txt; "$AGE" -d $P/identity.age | "$KEYGEN" -y | cmp - $P/recipient.txt && echo "identity matches recipient"
# 2. Initialise: the JSON goes straight into age
test -n "$P" && test -s $P/recipient.txt && test ! -e $P/init.json.age \
  && ssh -o BatchMode=yes debian@10.10.0.12 'BAO_ADDR=http://127.0.0.1:8200 bao operator init -key-shares=3 -key-threshold=2 -format=json' \
  | "$AGE" -R $P/recipient.txt -o $P/init.json.age && chmod 400 $P/init.json.age && echo "init saved"
"$AGE" -d -i $P/identity.age $P/init.json.age | jq -r '"shares=\(.unseal_keys_b64|length) threshold=\(.unseal_threshold) root_token=\(.root_token|length>0)"'
# 3. One file per share
for i in 1 2 3; do test ! -e $P/share-$i.age && "$AGE" -d -i $P/identity.age $P/init.json.age | jq -er ".unseal_keys_b64[$((i-1))]" \
  | tr -d '\n' | "$AGE" -R $P/recipient.txt -o $P/share-$i.age && chmod 400 $P/share-$i.age || { echo "stopped at share $i"; break; }; done
# 4. Unseal with shares 1 and 2 (section "Unseal")
# 5. The admin's password, then the bootstrap: root token on line 1, password on line 2
test ! -e $P/admin-password.age && openssl rand -base64 32 | tr -d '\n' | "$AGE" -R $P/recipient.txt -o $P/admin-password.age \
  && chmod 400 $P/admin-password.age && echo "password saved"
{ "$AGE" -d -i $P/identity.age $P/init.json.age | jq -r .root_token; "$AGE" -d -i $P/identity.age $P/admin-password.age; } \
  | ssh -o BatchMode=yes debian@10.10.0.12 akasha-bao-bootstrap
# 6. Checks (admin login, seal, unseal with shares 3 and 1), then: shred -u $P/init.json.age
```

`akasha-bao-bootstrap` ends with "admin created (policies: admin,default); root token revoked".
It can run again until the root token is revoked; after that it refuses the token.

## Bump the pinned OpenBao version

OpenBao is not in Debian's archive: unattended upgrades never patch it. Renovate opens a pull
request that changes only `openbao_version` (ADR-0042). For a new release, on the laptop, in an empty directory:

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
  release workflow's identity. cosign is not in the pinned toolchain (ADR-0042), so
  only the GPG signature is checked.
* **Read the release and upgrade notes.**
* **Change** `openbao_version`, `openbao_deb_sha256` and `openbao_published_at` in
  `infra/ansible/roles/openbao/defaults/main.yml`: on Renovate's pull request, add a commit
  with the SHA-256 and the publication time.
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
* OpenBao's TLS port 8200 from the bastion only (ADR-0047);
* ping from `br-mgmt` and the tailnet;
* nothing else.

Drops are logged:

```bash
sudo journalctl -k -g 'akasha drop' -n 20
```

Test from a VM that is not a source, for example `os-ctl01`: `nc -zv -w3 10.10.0.12 8200` must
**time out** (dropped by the firewall). Then the drop shows in the log above.

An nftables package upgrade (unattended upgrades) restarts `nftables.service`. Its stop
flushes the rules, so `core` accepts everything for a moment until the rules load again.

Locked out: on the serial console (runbook `lab-vms.md`), `sudo nft flush ruleset`, then fix
the role and run it again.

## Roll back

Since step 7c-2, `/srv/openbao` holds every secret of the lab: never delete it without a
verified backup.

```bash
sudo systemctl disable --now openbao && sudo apt purge openbao
sudo rm -rf /srv/openbao /opt/openbao /etc/systemd/system/openbao.service.d /var/cache/akasha/openbao_*.deb
sudo systemctl daemon-reload
sudo systemctl disable --now nftables     # stopping it flushes the rules
```

Or rebuild `core` (runbook `opentofu-l0.md`, "Rebuilding one VM"): the data disk is kept.
