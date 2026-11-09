---
status: accepted
date: 2026-11-08
decision-makers: dhuy21
---

# OpenTofu with pinned libvirt and OpenStack providers

## Context and Problem Statement

State files will contain secrets (e.g. OpenStack application credentials). The TD2 code used
Terraform with the OpenStack provider `~> 1.54`, two major versions behind.

## Considered Options

* Terraform
* OpenTofu

## Decision Outcome

Chosen option: "OpenTofu", because it offers client-side state encryption (key provider
backed by OpenBao Transit, passphrase for the bootstrap stack) and is open source (MPL),
while keeping the same language and providers.

* `dmacvicar/libvirt` pinned to `= 0.9.9` (recent rewrite; known gotchas: cloud-init ISO in
  `/tmp`, `user_data` stored in state, immutable volumes, networks replaced on change).
* `terraform-provider-openstack/openstack` `~> 3.4` with the port-based pattern
  (security groups on ports, `openstack_networking_floatingip_associate_v2`).
* One state per layer (L0 host, L1 OpenStack VMs, L2 OpenStack resources, L3 K8s).
  L1–L3 states live in the in-lab S3 (versitygw) with lockfile locking. The L0/bootstrap stack
  creates the `core` VM that hosts that S3, so it cannot store its own state there: its first
  apply runs from the operator laptop, its state is encrypted with a `pbkdf2` passphrase kept
  outside OpenBao, and its final location is an open question (`docs/open-questions.md`).

### Consequences

* Good, because secrets in state are encrypted at rest.
* Bad, because OpenTofu's OpenBao key provider is documented against Vault 1.14 semantics and
  must be verified with OpenBao 2.7.
