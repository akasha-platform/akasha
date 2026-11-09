# 07 — Trust and data (OpenBao, PKI, S3, backups)

Researched: 2026-11-08. Prices and free tiers change often; **re-check before signing up**.

## OpenBao

**Status** — **VERIFIED**
- Latest release is **v2.7.2** (2026-10-26). The 2.6.x line is still patched. https://github.com/openbao/openbao/releases
- OpenBao moved to **OpenSSF** as a sandbox project in June 2025. https://openssf.org/tag/project/
- Incubation was a stated 2026 goal; whether it happened is **unconfirmed**.

**Footprint**
- About 40 MiB idle with Raft in Docker. **VERIFIED** (one data point): https://jacar.es/en/how-to-install-openbao-with-docker/
- Budget 128–256 MB for the process. **ESTIMATED**

**Storage**
- Integrated Raft, which needs `cluster_addr` even on a single node. **VERIFIED**: https://openbao.org/docs/configuration/storage/raft/
- A 3-node Raft cluster on one physical host adds nothing, so akasha runs **one node** and takes `raft snapshot` backups. **INFERRED**

### Seal options without a cloud KMS

| Seal | Behaviour | Tag / source |
|---|---|---|
| **Shamir (chosen)** | Starts sealed after every reboot; a human enters the key shares | VERIFIED: https://openbao.org/docs/concepts/seal/ |
| Static (`seal "static"`) | AES-256 key from `file://` or `env://`, supports rotation; the docs urge careful evaluation; lose the key and the data is unrecoverable | VERIFIED: https://openbao.org/docs/configuration/seal/static/ |
| Transit | Needs another Vault/OpenBao; on one host it inherits the same unseal problem | VERIFIED / INFERRED: https://openbao.org/docs/configuration/seal/transit/ |
| PKCS#11 / SoftHSM | Needs an HSM build or plugin; SoftHSM on the same VM is effectively a key file | VERIFIED / INFERRED: https://openbao.org/docs/configuration/seal/pkcs11/ |

**Why Shamir.** The project owner chose to show manual unseal, the posture many companies use.

**Consequence after a host reboot.** Until someone unseals OpenBao, nothing that depends on it works:
- External Secrets refresh;
- cert-manager renewals;
- `kolla-readpwd`;
- CI logins;
- OpenTofu transit decryption.

Secrets already synced into Kubernetes stay in etcd, so running workloads survive. **INFERRED** — this must go into the reboot runbook.

### Placement

- HashiCorp and Google recommend running Vault in a dedicated cluster, or isolated from the workloads it serves. **VERIFIED**: https://developer.hashicorp.com/vault/tutorials/kubernetes/kubernetes-raft-deployment-guide , https://cloud.google.com/blog/products/identity-security/exploring-container-security-running-and-connecting-to-hashicorp-vault-on-kubernetes
- **Not in K3s:** K3s, Kolla and OpenTofu all consume OpenBao, so running it in K3s creates a bootstrap loop.
- **Not on the bastion:** the bastion executes CI-triggered code and is the most exposed VM.
- **Chosen:** a dedicated **`core` VM (0.75 GB)** running OpenBao + versitygw. **INFERRED**

### What OpenBao replaces

| Capability | Replaces | Notes |
|---|---|---|
| PKI intermediate + ACME (`/v1/pki/acme/directory`) | smallstep step-ca | **VERIFIED**: https://openbao.org/docs/api/secret/pki/ . The root CA stays **offline** (age-encrypted, on USB). |
| KV v2 | ansible-vault for Kolla `passwords.yml` | `kolla-readpwd`/`kolla-writepwd` use KV v2 through hvac (**VERIFIED**, see [03](03-kolla-2026.1-findings.md)). Compatibility with OpenBao is **INFERRED**; test it. |
| JWT auth | Long-lived CI tokens | GitHub OIDC with `bound_claims` on `repository_id` + environment/ref. **VERIFIED**: https://openbao.org/docs/auth/jwt/ |
| Transit | Passphrase-based state encryption | OpenTofu `key_provider "openbao"` is documented against Vault 1.14 semantics; verify with 2.7. **VERIFIED**: https://opentofu.org/docs/language/state/encryption/ |
| SSH CA | Static SSH keys | Signed user and host certificates. **VERIFIED**: https://openbao.org/docs/secrets/ssh/signed-ssh-certificates/ |

**cert-manager Vault issuer**
- Supports token, AppRole, Kubernetes and JWT auth, and must use the `sign` endpoint. JWT is recommended when Vault runs outside the cluster. **VERIFIED**: https://cert-manager.io/docs/configuration/vault/
- OpenBao is not mentioned in those docs, so compatibility is **INFERRED** from a third-party showcase: https://fabianhardt.github.io/k3d-bootstrap-cluster/showcases/openbao.html

**Stays outside OpenBao.** These must be recoverable when OpenBao itself is down:
- Shamir key shares and recovery procedure;
- the offline root CA key;
- the passphrase for the OpenTofu stack that creates the `core` VM, since that stack cannot encrypt its state with OpenBao;
- Tailscale admin credentials;
- the restic password and off-site S3 credentials;
- the break-glass `generate-root` procedure.

## External Secrets Operator

- **Version:** v2.14.0. CVE-2026-22822 affected 0.20.2–1.2.0, and current versions are past that range. **VERIFIED**: https://github.com/external-secrets/external-secrets/releases
- **OpenBao support:** there is no dedicated provider. ESO's docs say to use the Vault provider, and it was tested with old versions only. **VERIFIED**: https://external-secrets.io/latest/provider/openbao/
- **Auth:** use **JWT auth** with `jwt_validation_pubkeys` set to the K3s service-account signing key, so OpenBao never needs to call the K3s API. **INFERRED**: https://external-secrets.io/latest/provider/hashicorp-vault/
- **Footprint:** about 200–300 MB for 3 pods. **ESTIMATED**

## In-lab S3

Kolla 2026.1 removed Swift, and MinIO's community edition was archived on 2026-04-25 (**VERIFIED**: https://github.com/minio/minio). akasha therefore needs its own S3 endpoint for:
- OpenTofu state;
- K3s etcd snapshots;
- CloudNativePG backups;
- OpenBao snapshots.

| Option | Verdict | Evidence |
|---|---|---|
| Garage | **Rejected.** No conditional writes, so OpenTofu `use_lockfile` (which relies on `If-None-Match: *`) cannot lock | **VERIFIED**: https://garagehq.deuxfleurs.fr/documentation/reference-manual/known-issues/ , https://fossies.org/linux/opentofu/rfc/20250211-s3-locking-with-conditional-writes.md |
| **versitygw (chosen)** | Stateless gateway over a POSIX directory; `If-None-Match: *` works on unversioned buckets; small RAM. Plain files on disk, so restic can back them up directly | **VERIFIED**: https://github.com/versity/versitygw/issues/2480 |
| SeaweedFS (fallback) | 300 of 300 OpenTofu locking test pairs correct (v4.52); versioning race fixed 2026-11-06 | **VERIFIED**: https://github.com/seaweedfs/seaweedfs/issues/12453 |
| RustFS | 1.0 GA in Sep 2026; conditional writes unverified | Too new |

**Acceptance tests before trusting the chosen store:**
- two concurrent `If-None-Match: *` writes, where exactly one must get **412**;
- a barman-cloud backup and restore;
- K3s `etcd-s3` snapshots.

**S3-compatible checksum issue with barman-cloud:** set `AWS_REQUEST_CHECKSUM_CALCULATION=when_required` and `AWS_RESPONSE_CHECKSUM_VALIDATION=when_required`. **VERIFIED**: https://cloudnative-pg.io/plugin-barman-cloud/docs/object_stores/

## Off-site backups

The campus NFS share is **not used**, by policy. Off-site means a cloud object store, written with **restic** (encrypted, deduplicated). Only restic snapshots go off-site, not raw WAL, to keep the volume small. Disks of ctl and cmp VMs are rebuilt from code, not backed up.

| Provider | Free tier | Immutability | Source |
|---|---|---|---|
| Backblaze B2 | First 10 GB | S3 Object Lock | **VERIFIED**: https://www.backblaze.com/cloud-storage/pricing |
| Cloudflare R2 | 10 GB-month, free egress | No S3 Object Lock (bucket locks only) | **VERIFIED**: https://developers.cloudflare.com/r2/pricing/ |
| IDrive e2 | 10 GB reported | Object lock reported | Third-party only |
| Hetzner (EU) | None (€6.49/TB-month) | Object lock listed | **VERIFIED**: https://www.hetzner.com/storage/object-storage |
| Scaleway | 75 GB storage tier ended | — | **VERIFIED**: https://scaleway.com/en/docs/faq/objectstorage |

**Decision: AWS S3 Standard + Object Lock** (the project owner's choice).
- AWS free-tier terms and current prices are **NOT yet verified**. Check before creating the bucket.
- Use a restic key **without delete permission**, and lifecycle rules for retention. **INFERRED**
