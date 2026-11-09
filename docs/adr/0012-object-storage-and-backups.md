---
status: accepted
date: 2026-11-08
decision-makers: dhuy21
---

# Object storage and backups

## Context and Problem Statement

Kolla 2026.1 no longer deploys Swift. OpenTofu state, K3s etcd snapshots, CloudNativePG
backups and OpenBao snapshots need S3. Backups must also leave the host (3-2-1 rule).
The campus NFS share may not be used.

## Considered Options

* In-lab S3: Garage · SeaweedFS · versitygw (MinIO community edition is archived)
* Off-site: Backblaze B2 · Cloudflare R2 · AWS S3 (others reviewed: IDrive e2, Hetzner, Scaleway)

## Decision Outcome

* In-lab S3: **versitygw** on the `core` VM (stateless gateway over a directory on its data
  disk). Garage was rejected: its documentation states conditional writes are impossible, so
  OpenTofu `use_lockfile` cannot work. SeaweedFS is the fallback.
* Off-site: **restic** (encrypted, deduplicated) to **AWS S3 Standard with Object Lock** —
  the owner's choice. Research had recommended Backblaze B2 (Object Lock and per-key
  capabilities allowing a restic key without delete rights); AWS was preferred instead.
  Only small critical data goes off-site (configs, database dumps, state, CA material);
  VM disks are rebuilt from code.
* Design intent, **pending test A13**: a backup credential that cannot destroy history. On AWS,
  Object Lock requires a versioned bucket and `restic forget/prune` deletes objects, so the
  final design needs a separate maintenance credential or a retention/lifecycle scheme.

### Consequences

* Good, because state locking and immutable off-site copies are possible.
* Bad, because the restic + AWS Object Lock combination and its cost are not yet verified
  (`docs/open-questions.md` A13, C7).

### Confirmation

Before use: two concurrent `If-None-Match: *` writes must yield exactly one 412 (A3);
barman-cloud and K3s etcd-s3 uploads must succeed (A4); a restore drill must pass (A12).
