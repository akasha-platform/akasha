---
status: accepted
date: 2026-11-09
decision-makers: dhuy21
---

# PostgreSQL with CloudNativePG

## Context and Problem Statement

TD2 ran a hand-written PostgreSQL StatefulSet on `local-path` storage, without backups, and the
backend opened a new connection per request.

## Considered Options

* Keep a hand-written StatefulSet · Bitnami chart · CloudNativePG operator

## Decision Outcome

Chosen option: "CloudNativePG" (CNCF Sandbox, 1.30.x): declarative clusters, Prometheus
metrics, `Pooler` (PgBouncer) for connection pooling, continuous backups and point-in-time
recovery through the **Barman Cloud plugin** (the in-tree `barmanObjectStore` is removed in
1.31) to the in-lab S3 (`endpointCA` for the private CA). Volumes on Cinder CSI. Separate
clusters for `dev` and `prod`. Bitnami was rejected (free images withdrawn in 2025).

### Consequences

* Good, because backups/PITR and pooling come from a maintained operator.
* Bad, because the operator and plugin sidecars cost memory (≈ 0.25 GB + instances).
