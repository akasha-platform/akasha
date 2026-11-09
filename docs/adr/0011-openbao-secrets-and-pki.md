---
status: accepted
date: 2026-11-08
decision-makers: dhuy21
---

# OpenBao for secrets, PKI and workload identity

## Context and Problem Statement

Kolla passwords, TLS certificates, Kubernetes secrets and CI credentials need one trustworthy
source, outside the systems that consume it.

## Considered Options

* Ansible Vault + smallstep step-ca + Sealed Secrets
* OpenBao + External Secrets Operator

## Decision Outcome

Chosen option: "OpenBao 2.7.x", single node with integrated Raft, on a dedicated `core` VM
(not in Kubernetes — bootstrap loop; not on the bastion — the most exposed VM). It provides:

* KV v2 for Kolla passwords (`kolla-readpwd`/`kolla-writepwd`) and app secrets
* PKI intermediate with ACME for Kolla TLS and cert-manager (root CA kept offline)
* Transit for OpenTofu state encryption
* SSH certificate authority
* JWT auth for GitHub Actions (OIDC), External Secrets Operator and cert-manager

Unseal: **Shamir, by hand after each host reboot** (owner's choice; static seal was the
alternative). Kept outside OpenBao: unseal shares, offline root CA key, bootstrap-stack
passphrase, Tailscale CI identity (workload-identity client) and Tailscale admin credentials,
restic password and off-site S3 key, break-glass procedure.

Acceptance tests before relying on it (inferred compatibility, not yet tested): `kolla-readpwd`
/ `kolla-writepwd` against OpenBao KV v2, cert-manager Vault issuer, OpenTofu `openbao` key
provider, External Secrets Operator Vault provider.

### Consequences

* Good, because no long-lived secrets live in CI or Git.
* Bad, because after a reboot nothing that depends on OpenBao works until it is unsealed;
  running workloads keep already-synced Kubernetes Secrets.

## More Information

[research/07-trust-and-data.md](../research/07-trust-and-data.md)
