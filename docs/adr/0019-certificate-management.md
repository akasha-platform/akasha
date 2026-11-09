---
status: accepted
date: 2026-11-09
decision-makers: dhuy21
---

# Certificate management: OpenBao PKI, cert-manager and trust-manager

## Context and Problem Statement

OpenStack APIs, platform endpoints and in-lab S3 need TLS from a private CA, renewed
automatically, with the CA trusted by every client.

## Decision Outcome

* Root CA created and kept **offline** (encrypted); it signs an intermediate CA held by OpenBao
  PKI (ADR-0011), which also exposes ACME.
* Kolla HAProxy certificates are issued from OpenBao by Ansible and written as PEM files
  (`kolla_copy_ca_into_containers`).
* In Kubernetes, **cert-manager** uses the Vault issuer (sign endpoint) against OpenBao with
  JWT auth; **trust-manager** distributes the root CA to namespaces.
* step-ca was rejected once OpenBao covered PKI.

### Consequences

* Good, because one PKI serves the whole lab and renewal is automatic.
* Bad, because cert-manager does not document OpenBao: compatibility is an acceptance test
  (open-questions A6).
