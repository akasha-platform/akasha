---
status: accepted
date: 2026-11-08
decision-makers: dhuy21
---

# Replace DevStack with Kolla-Ansible 2026.1 on Debian 13

## Context and Problem Statement

The TD2 lab used DevStack, which broke after almost every reboot. DevStack's own FAQ states
it is for development and CI, not for persistent use, and it has no upgrade path.

## Considered Options

* Keep DevStack
* Kolla-Ansible
* OpenStack-Ansible (LXC containers)
* Canonical Sunbeam

## Decision Outcome

Chosen option: "Kolla-Ansible", release **2026.1 Gazpacho** (SLURP, direct upgrade path to
2027.1), on **Debian 13** hosts. Kolla is Ansible-driven like the rest of the repo, restarts
containers after reboots, supports `upgrade`, `mariadb-recovery` and `mariadb-backup`, and is
the most used self-deployed tool alongside OpenStack-Ansible (2023 survey: 59 vs 58
production users). Sunbeam was rejected (Ubuntu only, 16 GiB single-node / 32 GiB per HA node).

Verified 2026.1 specifics to handle: Swift is removed; Heat and fluentd are enabled by
default; `cinder_backup` defaults to a Ceph driver; Galera buffer pool defaults to 40% of
RAM; chrony is no longer deployed (host NTP required); Secure RBAC defaults are enforced.

### Consequences

* Good, because the cloud survives reboots and can be upgraded.
* Bad, because single-controller Galera recovery after power loss is unclear and must be tested.

### Confirmation

Cold-boot test (`virsh destroy` of all VMs) and documented recovery runbook in phase P2.

## More Information

[research/03-kolla-2026.1-findings.md](../research/03-kolla-2026.1-findings.md)
