---
status: accepted
date: 2026-11-26
decision-makers: dhuy21
---

# Off-site backups: restic to AWS S3 with Object Lock in compliance mode

## Context and Problem Statement

[ADR-0012](0012-object-storage-and-backups.md) sends small critical data off-site with restic,
to AWS S3 with Object Lock. It left open how a backup credential could be unable to destroy
history while restic still prunes (open question A13). Step 7 created data that exists once
only:
* in `~/akasha-private` on the laptop: the unseal shares, the root CA key, the age identity
  (encrypted), backend files and other private files;
* OpenBao's Raft data on `core`'s data disk, on `insa`'s only NVMe drive.

The laptop's disk is not encrypted, and `insa` is the school's.

The owner split step 7e on 2026-11-26:
* 7e-1, this ADR: the bucket, the design, and the laptop's backup with a restore test;
* 7e-2: OpenBao's Raft snapshots from `core`.

Facts checked on 2026-11-26:
* **Object Lock** (AWS user guide, "Object Lock" and "Object Lock considerations"):
  * it requires versioning;
  * a simple DELETE (no version ID) still succeeds and adds a delete marker; the locked
    version remains;
  * retention and legal holds do not prevent new versions or delete markers;
  * a locked version cannot be deleted by a lifecycle expiration;
  * uploads need `Content-MD5` or an SDK checksum header;
  * a default retention is applied per object version, counted from its upload.
* **restic 0.20.0**, published 2026-11-19:
  * it sends upload checksums for S3, which makes Object Lock buckets usable (CHANGELOG,
    #2202). It also has two security fixes for `restore`;
  * its `SHA256SUMS` carries a good signature by key `CF8F 18F2 8445 7597 3F79 D4E1 91A6
    868B D3F7 A907`, the one in restic's installation docs;
  * the Linux binary's SHA-256 matches `mise.lock`. mise records no provenance for it.
* **`aws configure export-credentials --profile <p> --region eu-west-3`** returns the temporary
  credentials of an `aws login` session (AWS CLI 2.40.0, checked on the laptop). restic reads
  them from the environment.
* **Prices** (AWS Price List, eu-west-3, published 2026-11-25): S3 Standard $0.024 per GB-month,
  $0.0053 per 1 000 PUT, $0.0042 per 10 000 GET. `~/akasha-private` holds 644 KB in 43 files,
  so the cost is far below one cent a month.

## Decision Drivers

* A single place of loss (laptop, `insa`) must not lose the lab's secrets.
* Nobody holding the backup credential, the admin's session included, may destroy recent
  history.
* Restore must not depend on anything inside the backup, nor on the laptop.
* Nothing readable leaves the machine.

## Considered Options

* **Object Lock mode:** **compliance**; governance.
* **Default retention:** 30, **90** or 365 days.
* **Prune:**
  * **delete markers by the backup user, with lifecycle cleanup after the lock**;
  * a separate maintenance user with delete rights.
* **Laptop schedule:** **by hand after each change**; a daily timer with a long-lived key.
* **IAM user:** **a new `akasha-backup`**; extending `akasha-l0`.
* **Repository password:**
  * **the keyring with a paper copy**;
  * an age file (inside the data it protects).

## Decision Outcome

Chosen by the owner on 2026-11-26 (the options in bold).

* **Bucket `akasha-backup-<random>`** in `eu-west-3`, created by hand (runbook
  [backups.md](../runbooks/backups.md)); its name is private:
  * Object Lock **compliance**, default retention **90 days** (versioning on);
  * public access blocked, bucket owner enforced, SSE-S3, TLS-only bucket policy;
  * lifecycle: noncurrent versions expire 7 days after they became noncurrent, and never
    while locked. Expired delete markers and incomplete uploads are removed.
* **IAM user `akasha-backup`**: `aws login` with MFA on the owner's phone and a console
  password kept off the laptop. Policy `akasha-backup-repo`:
  * allowed: list the bucket and its versions, read, add and delete-mark objects, read
    retentions;
  * explicitly denied: deleting versions, changing retentions, legal holds or the governance
    bypass, and changing the lock, lifecycle, policy, versioning or the bucket itself.
* **restic 0.20.0**, pinned with mise. One repository per source, each with its own
  password, so that `core` (7e-2) never holds the password of the laptop's secrets:
  * `laptop`: `~/akasha-private`, with `--host akasha-laptop`;
  * its password is in the keyring (service `akasha-restic`, user `laptop`) and on paper,
    with the bucket name.
  * `tofu_passphrase.py` gained `--service` and `--plain` to serve it as
    `RESTIC_PASSWORD_COMMAND`. OpenTofu's use of it is unchanged.
* **Backups by hand** after each change of `~/akasha-private`, with the session's temporary
  credentials. Every snapshot is kept for now; `forget --prune` only places delete markers.
* **Recovery** needs, off the laptop: the `akasha-backup` password, the phone (MFA), and the
  paper with the repository password and the bucket name.

### Consequences

* Good, because losing the laptop or `insa` no longer loses the lab's secrets.
* Good, because for 90 days after an upload nobody can delete it, neither the backup user nor
  `akasha-admin` nor root. A leaked laptop session cannot wipe recent history.
* Good, because the bucket only ever holds data encrypted by restic.
* Bad, because the lock covers each object for 90 days from its upload. Data that never
  changes is later protected only by the backup user's policy, not against an admin.
* Bad, because compliance mode cannot be undone: the bucket and every object stay for at least
  90 days after their last upload, and nothing uploaded by mistake can be removed sooner
  (restic encrypts everything, so nothing readable is exposed).
* Bad, because backups are manual: a change forgotten is a change not backed up.
* Bad, because one more password exists, in the keyring and on paper.

### Confirmation

Before relying on it:
* the bucket reports versioning on and COMPLIANCE for 90 days;
* `restic init`, `backup` and `check` succeed, with no error;
* a restore into a temporary directory is identical to `~/akasha-private` (`diff -r`);
* restic accepts the password typed from paper;
* on a locked version, `get-object-retention` shows COMPLIANCE, and deleting it is refused
  for both `akasha-backup` and `akasha-admin`.

## More Information

* AWS: https://docs.aws.amazon.com/AmazonS3/latest/userguide/object-lock.html,
  https://docs.aws.amazon.com/AmazonS3/latest/userguide/object-lock-managing.html.
* restic: https://restic.readthedocs.io/ (v0.20.0), CHANGELOG #2202.
* ADR-0012, ADR-0022 (pinned toolchain), ADR-0031 (`aws login`, IAM users), ADR-0044, ADR-0045.
