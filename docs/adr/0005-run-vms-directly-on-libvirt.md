---
status: accepted
date: 2026-11-08
decision-makers: dhuy21
---

# Remove the Proxmox layer; run VMs directly on libvirt

## Context and Problem Statement

The existing lab ran Proxmox VE as a VM inside libvirt on the physical host, with OpenStack
inside Proxmox. Kubernetes VMs created by Nova would then run at nesting level 3
(host → Proxmox → compute → K8s VM).

## Decision Drivers

* Red Hat (RHEL 10 docs): L3 guests "have not been properly tested and are not expected to work"
* Red Hat measurements: L3 shell loop +140% vs L2, OS install 1297 s vs 370 s
* Proxmox VM overhead (~1.5 GB) on a 31 GB host
* Production fidelity: OpenStack computes run on bare metal, tenant VMs one level below

## Considered Options

* Keep Proxmox (layouts A/A′)
* Remove Proxmox; OpenStack nodes as libvirt VMs on the host (layout F)

## Decision Outcome

Chosen option: "layout F", because K8s VMs drop to nesting level 2, ~1.5 GB is recovered,
and the parent/child relation mirrors production. VMs are managed with OpenTofu
(`dmacvicar/libvirt`), vCPUs pinned to P-cores for OpenStack nodes.

### Consequences

* Good, because performance and stability of K8s guests improve.
* Bad, because Proxmox skills, GUI and vzdump backups are lost; the libvirt provider 0.9.x
  is a recent rewrite with known gotchas.

## More Information

[research/02-topology-and-nesting.md](../research/02-topology-and-nesting.md)
