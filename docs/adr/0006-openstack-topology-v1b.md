---
status: accepted
date: 2026-11-08
decision-makers: dhuy21
---

# OpenStack topology: 1 controller + 2 computes, 3 OVN gateway chassis

## Context and Problem Statement

About 23 GB of RAM is available for OpenStack nodes. Which multi-node topology is the most
production-faithful while leaving enough guest RAM (~10–12 GB) for Kubernetes?

## Decision Drivers

* No vendor calls fewer than 3 controllers "production"; 1 controller + N computes is a
  PoC/test layout everywhere (Red Hat, Kolla, Sunbeam, Mirantis)
* Each extra node costs 1–1.5 GB of overhead
* Demonstrable mechanisms: scheduling, anti-affinity, live migration, evacuation, gateway failover

## Considered Options

* 3 converged nodes with HA control plane — rejected: vendors size these at 16–32 GB per node
* 1 controller + 1 dedicated network node + 2 computes — rejected for now: −1.0–1.5 GB guest RAM
* 1 controller + 1 dedicated storage node + 2 computes — rejected: no HA benefit with LVM
* 1 controller + 3 small computes — real etcd quorum across hypervisors, but too little RAM for the platform
* 1 controller + 1 large compute — most guest RAM, but no anti-affinity or live migration
* **1 controller + 2 computes, computes and controller as OVN gateway chassis (V1b)**

## Decision Outcome

Chosen option: "V1b". `os-ctl01` (8 GB) runs the control plane, API VIP and Cinder LVM;
`os-cmp01`/`os-cmp02` (~7.6 GB) run Nova and act as OVN gateway chassis together with the
controller (three chassis, as OpenStack-Ansible recommends for reliable failover). One Nova
availability zone per compute (host aggregates; `neutron_ovn_availability_zones` only sets
router-gateway AZs and needs per-host `host_vars`). Distributed floating IPs.

Evolution: after measuring real overhead, if ≥1.5 GB is spare, add `net01` with Kolla's
"adding hosts" procedure and move HAProxy/gateways to it.

### Consequences

* Good, because gateway failover, live migration and evacuation can be exercised.
* Bad, because the control plane is a single point of failure (documented, not hidden).
* Risk: 8 GB may be tight for the controller. Measured references: a Kolla 2026.1 all-in-one
  used ≈ 12.3 GB right after deploy, a lab OVN controller needed "about 10 GB", and Kolla's own
  CI hit the OOM killer on 8 GB nodes during Octavia tests. Mitigation: low-RAM tuning, measure
  after deploy, defer Octavia if needed, rebalance RAM from the computes.
* Neutral: evacuating a member of a hard anti-affinity pair with 2 computes fails with
  "No valid host" — expected behaviour, used as a failure drill.

## More Information

[research/02-topology-and-nesting.md](../research/02-topology-and-nesting.md),
[architecture overview §7](../architecture/overview.md)
