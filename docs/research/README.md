# Research notes

Researched: 2026-11-08. Versions, prices and project status change quickly, so re-check everything here before you rely on it.

These notes record the evidence behind akasha's architecture decisions. Each decision has its own record in [`../adr/`](../adr/); the notes are the supporting evidence for those records.

## Method

- **Primary sources first:** official project documentation (OpenStack, Kolla-Ansible, Kubernetes, K3s, libvirt, GitHub, OpenBao and others), vendor reference architectures (Red Hat, Canonical, Mirantis, VEXXHOST), and release notes.
- **Source code where the docs were silent:** Kolla-Ansible defaults were read from shallow clones of `stable/2026.1` (HEAD `622a586`, 2026-11-06) and `stable/2026.2`. Code paths are cited as `KA/<path>`, which means `https://opendev.org/openstack/kolla-ansible/src/branch/stable/2026.1/<path>`.
- **Secondary sources** (blogs, forums, issue trackers) are used only for measurements or field reports, and are labelled as such.
- Some Red Hat documentation pages returned HTTP 403 to automated fetches. Claims taken from them rely on search-result snippets, and each note says so where it applies.

## Tags

| Tag | Meaning |
|---|---|
| **VERIFIED** | Read in an official or primary source, or in the cited source code. |
| **INFERRED** | Reasoned from verified facts, but not tested in this lab. |
| **ESTIMATED** | A number from arithmetic, anecdotes or judgement. It must be measured after deployment. |

## Index

| # | Note | Topics |
|---|---|---|
| 01 | [Private cloud with OpenStack](01-private-cloud-openstack.md) | Why OpenStack, DevStack limits, deployment tools, releases |
| 02 | [Topology and nesting](02-topology-and-nesting.md) | Nested virtualization depth, host layouts, node roles, compute count, N+1 |
| 03 | [Kolla-Ansible 2026.1 findings](03-kolla-2026.1-findings.md) | Verified defaults, gotchas, tuning, TLS, backups, power loss |
| 04 | [Host and network](04-host-and-network.md) | libvirt bridges, routing/NAT, Tailscale, OPNsense, DNS/NTP, images, CPU pinning, storage |
| 05 | [Kubernetes on OpenStack](05-kubernetes-on-openstack.md) | K3s topology, OCCM/Cinder CSI, load balancers, MTU, RAM budget, runner isolation |
| 06 | [CI/CD and supply chain](06-cicd-supply-chain.md) | Runner safety on public repos, image builds, GitOps, Trivy incident, pinning, process |
| 07 | [Trust and data](07-trust-and-data.md) | OpenBao, PKI, External Secrets, in-lab S3, off-site backups |
| 08 | [Observability and host memory](08-observability-and-host-memory.md) | Metrics, logs, traces, SLOs, PostgreSQL, ingress; KSM, zswap, free page reporting |

## Privacy note

This repository is public. The host's Tailscale address, the campus network ranges and campus storage addresses are deliberately left out. Only the lab's own private ranges (`10.x`) and generic hardware facts appear here.
