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
  * it sends `Content-MD5` with every S3 upload, which makes Object Lock buckets usable. This
    has been so since 0.13.0 (CHANGELOG #2202). 0.20.0 also has two security fixes for
    `restore`;
  * its S3 calls are HeadBucket, GetObject, PutObject, ListObjectsV2, and DELETE without a
    version ID. Credentials come from the environment, the region from
    `AWS_DEFAULT_REGION`;
  * `backup`, `check` and `init` delete only lock files under `locks/`. `forget` and `prune`
    need full delete rights. restic's docs recommend an append-only client for backups, a
    separate well-secured client for maintenance, and `forget --keep-within` against garbage
    snapshots ("Security considerations in append-only mode");
  * its `SHA256SUMS` carries a good signature by key `CF8F 18F2 8445 7597 3F79 D4E1 91A6
    868B D3F7 A907`, the one in restic's installation docs;
  * the Linux binary's SHA-256 matches `mise.lock`. mise records no provenance for it.
* **`aws configure export-credentials --profile <p> --region eu-west-3`** returns the temporary
  credentials of an `aws login` session (AWS CLI 2.40.0, checked on the laptop). `aws login`
  renews them about every 15 minutes; restic reads them once from the environment.
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
* **Prune and lifecycle** (revised after the independent review):
  * delete markers by the backup user, and lifecycle cleanup of every noncurrent version
    once its lock ends. The first design; rejected, see below;
  * **an append-only backup user (it may delete lock files only), lifecycle limited to
    `locks/`, maintenance as `akasha-admin`**;
  * lifecycle limited to `locks/`, with the backup user still placing delete markers;
  * the admin extending retentions every month.

  The independent review showed the first design's flaw. Someone holding the backup
  credential deletes everything (markers only). Once their 90-day lock ends, the lifecycle
  deletes the old versions. Since restic deduplicates, the newest snapshot still needs
  `config`, `keys/` and old packs, so the whole repository would be lost.
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
  * lifecycle **only under `<repository>/locks/`**: old lock versions go 7 days after they
    became noncurrent, once unlocked. Incomplete uploads are aborted. Every version of the
    data is kept, deleted or overwritten alike, so the admin can recover it.
* **IAM user `akasha-backup`**: `aws login` with MFA on the owner's phone and a console
  password kept off the laptop. Policy `akasha-backup-repo`:
  * allowed: list the bucket and its versions, read and add objects, read retentions. It may
    delete (place a marker) under `*/locks/*` only: it is append-only;
  * explicitly denied: deleting versions, changing retentions, legal holds or the governance
    bypass, and changing the lock, lifecycle, policy, versioning or the bucket itself.
* **restic 0.20.0**, pinned with mise. One repository per source, each with its own
  password, so that `core` (7e-2) never holds the password of the laptop's secrets:
  * `laptop`: `~/akasha-private`, with `--host akasha-laptop`;
  * its password is in the keyring (service `akasha-restic`, user `laptop`) and on paper,
    with the bucket name.
  * `tofu_passphrase.py` gained `--service` and `--plain` to serve it as
    `RESTIC_PASSWORD_COMMAND`. OpenTofu's use of it is unchanged.
* **Backups by hand** after each change of `~/akasha-private`. The session's temporary
  credentials are exported again before each command block. Every snapshot is kept for now.
  `forget` and `prune`, if ever needed, run as `akasha-admin` with `--keep-within`.
* **Recovery** needs, off the laptop:
  * the `akasha-backup` password and the phone (MFA);
  * the paper with the repository password, the bucket name and the account ID.

  Undoing an attack (copying back older versions) also needs `akasha-admin`.
* **The point of no return** is the first upload (`restic init`): an empty bucket can still
  be deleted. After that, each object stays at least 90 days.

### Consequences

* Good, because losing the laptop or `insa` no longer loses the lab's secrets.
* Good, because the backup credential can only add: no data is deleted, and an overwrite keeps
  the old version.
* Good, because for 90 days after an upload no version can be deleted at all, not by
  `akasha-admin` and not by root. A leaked laptop session cannot wipe recent history.
* Good, because the bucket only ever holds data encrypted by restic.
* Bad, because the lock covers each object for 90 days from its upload. After that, only the
  backup user's policy protects data that never changes, and an admin can still delete it.
* Bad, because compliance mode cannot be undone: the bucket and every object stay for at least
  90 days after their last upload, and nothing uploaded by mistake can be removed sooner
  (restic encrypts everything, so nothing readable is exposed).
* Bad, because backups are manual: a change forgotten is a change not backed up.
* Bad, because one more password exists, in the keyring and on paper.
* Bad, because the backup credential can upload any amount. Each upload is billed and locked
  for 90 days; IAM cannot cap the size. The account's 1 USD budget alert only warns.
* Bad, because storage only grows: nothing but lock files is ever cleaned up by itself. At
  644 KB, that is negligible.

### Confirmation

Before relying on it:
* the bucket reports versioning on and COMPLIANCE for 90 days;
* `restic init`, `backup` and `check` succeed, with no error;
* a restore into a temporary directory is identical to `~/akasha-private` (`diff -r`);
* restic accepts the password typed from paper;
* on a canary object, `get-object-retention` shows COMPLIANCE. Deleting its version is refused
  for `akasha-backup` (policy) and for `akasha-admin` (Object Lock). Deleting `laptop/config`
  as `akasha-backup` is refused (append-only);
* undoing an attack (copying back older versions) is not rehearsed yet.

### Implementation (2026-11-27)

Made by hand from PR #81, following runbook `backups.md`.
* **The bucket.** Versioning Enabled; Object Lock COMPLIANCE for 90 days; lifecycle rules
  `locks-laptop` (prefix `laptop/locks/`) and `abort-multipart`.
* **The user `akasha-backup`.** Policies `akasha-backup-repo` and
  `SignInLocalDevelopmentAccess`, one MFA device, no forced password reset. The admin session
  was closed afterwards.
* **The paper sheet.** It holds the restic password, the bucket name and the account ID; the
  password was checked against the keyring.
* **The repository.** `restic init` created `laptop`, the point of no return. The first
  backup took 44 files (485 KiB; 319 KiB stored), and `restic check` found no errors. It took
  and removed an exclusive lock, so the append-only policy is enough for restic.
* **Restores.**
  * A restore to a temporary directory was identical to `~/akasha-private` (`diff -r`).
  * restic opened the repository with the password typed from paper, without the keyring.
* **The lock**, on a canary object `lock-canary-20261127`:
  * its retention read COMPLIANCE until 2027-02-25;
  * deleting its version as `akasha-backup` was refused by the explicit deny on
    `s3:DeleteObjectVersion`;
  * deleting `laptop/config` was refused, because no policy allows `s3:DeleteObject` outside
    `locks/`;
  * as `akasha-admin`, the refusal read "Access Denied because object protected by object
    lock".

## More Information

* AWS: https://docs.aws.amazon.com/AmazonS3/latest/userguide/object-lock.html,
  https://docs.aws.amazon.com/AmazonS3/latest/userguide/object-lock-managing.html.
* restic: https://restic.readthedocs.io/ (v0.20.0), CHANGELOG #2202.
* ADR-0012, ADR-0022 (pinned toolchain), ADR-0031 (`aws login`, IAM users), ADR-0044, ADR-0045.
