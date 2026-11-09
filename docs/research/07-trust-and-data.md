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
- **Declarative first start:** an `initialize` (self-init) stanza in the server config applies setup (auth methods, mounts, policies) on first start. **VERIFIED**: https://openbao.org/docs/configuration/self-init/ . The docs pair it with auto-unseal; with Shamir, check how it behaves (**OPEN**).

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
| Transit | Passphrase-based state encryption | OpenTofu `key_provider "openbao"` is documented against Vault 1.14 semantics; verify with 2.7. **VERIFIED**: https://opentofu.org/docs/language/state/encryption/ . OpenTofu 1.11 also has ephemeral resources (**VERIFIED**: https://opentofu.org/blog/opentofu-1-11-0); third-party guides use the `hashicorp/vault` v5 provider against OpenBao with `ephemeral "vault_kv_secret_v2"` and write-only `data_json_wo`, so secrets stay out of state (**INFERRED**: https://oneuptime.com/blog/post/2026-03-20-openbao-integration-opentofu/view). |
| SSH CA | Static SSH keys | Signed user and host certificates. **VERIFIED**: https://openbao.org/docs/secrets/ssh/signed-ssh-certificates/ |

**cert-manager Vault issuer**
- Supports token, AppRole, Kubernetes and JWT auth, and must use the `sign` endpoint. JWT is recommended when Vault runs outside the cluster. **VERIFIED**: https://cert-manager.io/docs/configuration/vault/
- OpenBao is not mentioned in those docs, so compatibility is **INFERRED** from a third-party showcase: https://fabianhardt.github.io/k3d-bootstrap-cluster/showcases/openbao.html

**Stays outside OpenBao.** These must be recoverable when OpenBao itself is down:
- Shamir key shares and recovery procedure;
- the offline root CA key;
- the **pbkdf2 passphrase** for the OpenTofu bootstrap stack that creates the `core` VM (that stack cannot encrypt its state with OpenBao); kept as a GitHub Actions secret plus an offline copy;
- the **Tailscale CI identity** (workload-identity / OAuth client used by `tailscale/github-action`);
- the **Tailscale admin credentials** (tailnet owner account);
- the restic password and off-site S3 credentials;
- the break-glass `generate-root` procedure.

**Acceptance tests for the OpenBao integrations** (each is **INFERRED** compatible; none has been tested):
1. `kolla-readpwd` / `kolla-writepwd` against OpenBao KV v2 (mount `kv`, hvac).
2. cert-manager Vault issuer (JWT auth, `sign` endpoint) issuing a certificate from the OpenBao intermediate.
3. OpenTofu `key_provider "openbao"` (Transit) encrypting and decrypting a state file.
4. External Secrets Operator Vault provider (JWT auth) syncing a KV v2 secret.
5. GitHub Actions OIDC login with `bound_claims` (repository_id + environment).

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
| **versitygw (chosen)** | Stateless gateway over a POSIX directory; `If-None-Match: *` works on unversioned buckets (**VERIFIED**); the delete-marker bug was fixed on 2026-10-08 (**VERIFIED**); RAM < 100 MB (**ESTIMATED**). Plain files on disk, so restic can back them up directly | https://github.com/versity/versitygw/issues/2480 , https://github.com/versity/versitygw |
| SeaweedFS (fallback) | 300 of 300 OpenTofu locking test pairs correct (v4.52); versioning race fixed 2026-11-06 | **VERIFIED**: https://github.com/seaweedfs/seaweedfs/issues/12453 |
| RustFS | 1.0 GA in Sep 2026; conditional writes unverified | Too new |

**Acceptance tests before trusting the chosen store:**
- two concurrent `If-None-Match: *` writes, where exactly one must get **412**;
- a barman-cloud backup and restore;
- K3s `etcd-s3` snapshots.

**S3-compatible checksum issue with barman-cloud:** set `AWS_REQUEST_CHECKSUM_CALCULATION=when_required` and `AWS_RESPONSE_CHECKSUM_VALIDATION=when_required`. With a private CA (versitygw served with an OpenBao certificate), set `endpointCA` in the plugin's object store. **VERIFIED**: https://cloudnative-pg.io/plugin-barman-cloud/docs/object_stores/

### OpenTofu S3 backend for a non-AWS endpoint

Settings documented by HashiCorp for S3-compatible stores (non-AWS support is "best effort"); OpenTofu's backend has the same options. **VERIFIED**: https://developer.hashicorp.com/terraform/language/backend/s3

```hcl
terraform {
  backend "s3" {
    bucket                      = "akasha-tfstate"
    key                         = "l1-openstack-vms/terraform.tfstate"
    region                      = "us-east-1"            # placeholder, ignored by versitygw
    endpoints                   = { s3 = "https://s3.akasha.internal:<port>" }  # versitygw on core
    use_path_style              = true
    skip_credentials_validation = true
    skip_region_validation      = true
    skip_requesting_account_id  = true
    skip_metadata_api_check     = true
    skip_s3_checksum            = true
    use_lockfile                = true                   # needs If-None-Match support (test first)
  }
}
```

`dynamodb_table` locking is deprecated in favour of `use_lockfile`. Applies are also serialised with a GitHub Actions `concurrency` group (see [06](06-cicd-supply-chain.md)).

### Where the bootstrap state lives — OPEN

The L0 stack that creates `core` (and therefore versitygw) and the bastion cannot store its state in the in-lab S3. The first apply runs from the operator laptop. The state is encrypted with OpenTofu's `pbkdf2` key provider (passphrase kept as a GitHub secret plus an offline copy). Where that encrypted state file lives (local file backed up with restic, a separate private store, …) is **not decided yet**. **INFERRED**

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
