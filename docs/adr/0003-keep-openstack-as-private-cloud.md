---
status: accepted
date: 2026-11-08
decision-makers: dhuy21
---

# Keep OpenStack as the private-cloud layer

## Context and Problem Statement

The platform needs an IaaS layer under Kubernetes. Paid public clouds are not an option.
Should the lab keep OpenStack, or provision VMs directly on the hypervisor?

## Decision Drivers

* Learn and demonstrate real cloud abstractions (projects, security groups, floating IPs,
  load balancers, block storage, Keystone identity)
* Transferable skills: OpenStack APIs are used by OVHcloud, Infomaniak, Open Telekom Cloud, CERN
* Limited RAM on one host

## Considered Options

* OpenStack on the host (Kolla-Ansible)
* VMs provisioned directly by OpenTofu on the hypervisor, no cloud layer
* Kubernetes-hosted OpenStack control plane (OpenStack-Helm, Sunbeam, RHOSO, Atmosphere)

## Decision Outcome

Chosen option: "OpenStack on the host", because it provides cloud-native integrations for
Kubernetes (cloud controller manager, Cinder CSI, Octavia) and portable OpenTofu code.
Kubernetes-hosted control planes are the vendor direction but need from 16 GB (Sunbeam single
node) to 192+ GB (Mirantis), or Ubuntu-only tooling, leaving too little memory for workloads.

### Consequences

* Good, because K8s integrates with the cloud the way production clusters do.
* Bad, because the OpenStack control plane costs ~8 GB of 31 GB and must be operated.

## More Information

[research/01-private-cloud-openstack.md](../research/01-private-cloud-openstack.md)
