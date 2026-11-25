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

## Updates

* 2026-11-25 (step 7, open question A14): **self-initialisation cannot be used with the Shamir
  seal**, so OpenBao is initialised by hand, over SSH on `core`, as
  [ADR-0039](0039-openbao-on-core-bootstrap.md) plans. The Shamir choice is unchanged.
  * VERIFIED in OpenBao 2.7.3:
    * The self-init documentation requires an auto-unseal mechanism.
    * In `internal/command/server.go`, `Initialize` returns the error "self-initialization
      requires auto-unseal as there is no way to persist the Shamir's keys" whenever the
      configuration has an `initialize` stanza and the seal has no recovery keys. The server
      then exits. This check runs before the one that skips an already initialised OpenBao.
  * Tested in a Debian 13 container, with the pinned package and `core`'s configuration plus
    an `initialize` stanza:
    * an uninitialised OpenBao exited with code 1 and that error;
    * initialised by hand (`bao operator init -key-shares=3 -key-threshold=2`) and unsealed
      with two of the three shares, then restarted with the stanza, it exited the same way;
    * restarted without the stanza, it started, initialised and sealed.

    The container and its keys were deleted.
  * Consequences:
    * A stanza left in the configuration would stop OpenBao at every start. The role writes
      none.
    * The mounts, auth methods and policies have to be configured by requests after the
      unseal, with a token.
    * When unsealing, give the share at `bao operator unseal`'s prompt, not as an argument,
      which other processes can read.
