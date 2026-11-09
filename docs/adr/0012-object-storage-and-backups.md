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

## Decision Outcome

* In-lab S3: **versitygw** on the `core` VM (stateless gateway over a directory).
  Garage was rejected: its documentation states conditional writes are impossible, so
  OpenTofu `use_lockfile` cannot work. SeaweedFS is the fallback.
  MinIO community edition is archived.
* Off-site: **restic** (encrypted, deduplicated) to **AWS S3 Standard with Object Lock**;
  the restic key cannot delete objects. Only small critical data goes off-site (configs,
  database dumps, state, CA material); VM disks are rebuilt from code.

### Consequences

* Good, because state locking and immutable off-site copies are possible.
* Bad, because AWS free-tier terms and costs are not yet verified.

### Confirmation

Before use: two concurrent `If-None-Match: *` writes must yield exactly one 412; barman-cloud
and K3s etcd-s3 uploads must succeed; a restore drill must pass.
