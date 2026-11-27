---
status: accepted
date: 2026-11-27
decision-makers: dhuy21
---

# OpenBao's daily off-site backup from core

## Context and Problem Statement

OpenBao's Raft data lives on `core`'s data disk ([ADR-0038](0038-data-disks-outlive-vms.md)),
on `insa`'s only NVMe drive. A rebuild of `core` keeps it; a lost disk or host does not.
[ADR-0048](0048-off-site-backups-restic-s3-object-lock.md) set up the bucket, with one restic
repository per source. Step 7e-2 adds the repository `core`, written every day by `core`
itself, with nobody at the keyboard. That needs three identities:
* one in OpenBao, to take a snapshot (the root token is revoked, and the admin is a person);
* one in AWS, since `core` cannot use `aws login`;
* a restic password.

Facts checked on 2026-11-27, in Debian 13 containers with OpenBao 2.7.3 and restic 0.20.0:
* **The AppRole resources of the Vault provider 5.13.0** work against OpenBao. A second
  plan is empty.
  * AppRole refuses `127.0.0.1` as a bound CIDR ("invalid CIDR address"): it wants
    `127.0.0.1/32`.
  * OpenBao then stores the token bound as `127.0.0.1`, and the provider absorbs the
    difference.
* **Login and the token's limits.**
  * `bao write auth/approle/login role_id=… secret_id=-` reads the secret from stdin.
  * The token holds `default` and `raft-snapshot`, lives 300 s, saves a snapshot, and is
    denied listing secrets engines.
  * A login through a non-loopback listener is refused.
* **The snapshot and its restore.**
  * restic backed the snapshot up and restored it.
  * A fresh OpenBao was initialised with its own key, then the snapshot was restored with
    `-force`. It then carried the original's seal (3 shares, threshold 2) and unsealed with two
    original shares.
  * The original's root token worked, and its mounts, PKI issuer and AppRole role were there.
* **Packages.** Debian 13 ships restic 0.18.0 (sources.debian.org); 0.20.0 is the pinned one.
* **Network.** `core` reaches the Internet: the router forwards `br-mgmt` to the WAN
  (`router_firewall`), and `insa` masquerades the lab (`host_firewall`).

## Decision Drivers

* No long-lived credential of more power than one append-only job needs.
* A leaked secret of `core` must not expose the laptop's repository (unseal shares, root CA).
* Fail visibly: a sealed OpenBao or a broken key must turn the role and the unit red.
* Restore must be tested, not assumed.

## Considered Options

* **OpenBao identity:** **AppRole**; a periodic token; by hand.
* **AWS identity:** **an access key of a dedicated user**; IAM Roles Anywhere with a client
  certificate from OpenBao's PKI.
* **restic on `core`:** **the pinned binary 0.20.0 with Renovate**; Debian's 0.18.0.
* **Schedule:** **daily, keep everything**; weekly; by hand.

## Decision Outcome

Chosen by the owner on 2026-11-27 (the options in bold).

* **OpenBao.** Stack `openbao`, `approle.tf`:
  * the `approle` auth method;
  * the policy `raft-snapshot`: `read` on `sys/storage/raft/snapshot`, nothing else;
  * the role `core-backup`: token and secret ID bound to `127.0.0.1/32`, tokens of 300 s
    (600 s at most).

  `akasha-bao-approle` runs on `core` as root, with the admin's token on stdin. It writes the
  role ID and a new secret ID in `/etc/akasha/backup` (root, 0600), destroys every older
  secret ID, and revokes the admin's token. The secret never leaves `core`.
* **AWS.** The IAM user `akasha-backup-core` has an access key and no console. Its policy
  `akasha-backup-core-repo` is append-only within `core/`:
  * read, write, read retention;
  * delete under `core/locks/` only;
  * the same explicit deny as `akasha-backup`.

  The lifecycle gains `locks-core`. The key and the repository password go from
  `create-access-key` and `openssl rand` straight into `~/akasha-private/backup_core.yml`,
  never on a screen. The `laptop` repository backs that file up.
* **restic 0.20.0** on `core`: the official `.bz2`, checked by SHA-256 in `get_url`, behind
  the cooldown, with a Renovate annotation (ADR-0042).
* **The job.** `akasha-openbao-backup.timer` runs daily at about 03:30 UTC (randomised 30 min,
  `Persistent`). The script:
  * logs in with the AppRole;
  * saves the snapshot to `/var/lib/akasha-backup`;
  * revokes the token;
  * runs `restic backup --host core --tag openbao`.

  The unit is sandboxed (`ProtectSystem=strict`, private `/tmp`, no new privileges).
  Everything is kept. `--init` creates the repository once.
* **Checks.** The role verifies the timer, the last result and that the newest snapshot is
  younger than 48 h. Until the AppRole's files exist, it stops with the steps to take.
* **Recovery chain.**
  1. The paper restores `laptop`.
  2. `laptop` holds `backup_core.yml`, which opens `core`.
  3. `core` gives the snapshot.
  4. Two shares unseal it.

### Consequences

* Good, because OpenBao's data now survives the loss of `insa`, and a restore is proven to
  bring it all back.
* Good, because every credential on `core` is narrow:
  * the AppRole only snapshots, from loopback, for 5 minutes;
  * the access key only adds within `core/`.

  A stolen snapshot is still sealed by OpenBao's barrier.
* Good, because a sealed OpenBao, a revoked key or a dead network turns the unit and the role
  red.
* Bad, because the access key is long-lived. It is rotated by hand (runbook) and is not
  checked for age; IAM Roles Anywhere would remove it.
* Bad, because the AppRole's secret ID never expires. It is rotated by running the helper
  again.
* Bad, because a snapshot a day, kept for at least 90 days, only grows (a few tens of KB each
  today).
* Bad, because the timer runs whether or not OpenBao is unsealed. After a reboot, the backups
  fail until someone unseals it, which is visible but not alerted.

### Confirmation

On `core`:
* the role's first run stops for the AppRole;
* the helper writes the files and destroys older secret IDs;
* `--init` creates the repository;
* a first run uploads a snapshot;
* a second role run passes every check.

From the laptop: restore the newest snapshot of `core` and check its size and date (the full
restore into a fresh OpenBao was tested in a container).

## More Information

* Runbook: [backups.md](../runbooks/backups.md), section "core".
* OpenBao AppRole and Raft snapshot APIs (v2.7.3 docs); restic 0.20.0.
* ADR-0045 (the admin), ADR-0046 and ADR-0047 (the stack `openbao`), ADR-0048.
