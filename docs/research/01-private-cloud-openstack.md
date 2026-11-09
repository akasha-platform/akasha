# 01 — Private cloud with OpenStack

Researched: 2026-11-08. Re-check versions and figures before use.

## Why OpenStack as a substitute for a paid public cloud

- The OpenInfra Foundation reported about **55 million cores** in production in 2025. CERN, Walmart and Workday each run 1M+ cores, and small and mid-sized businesses are the fastest-growing group. **VERIFIED (press release)** — https://www.finanzen.net/nachricht/aktien/openstack-deployments-grow-as-openinfra-community-marks-15-years-flamingo-release-14934687
- **OVHcloud** Public Cloud exposes the standard OpenStack APIs and Horizon. **VERIFIED** — https://docs.ovhcloud.com/en/guides/public-cloud/cross-functional/public-cloud-interface-walk-me
- **Infomaniak** Public Cloud is OpenStack, and it has offered managed Kubernetes since April 2025. **VERIFIED** — https://www.infomaniak.com/en/hosting/public-cloud
- **Open Telekom Cloud** is OpenStack-based. **VERIFIED (vendor blog)** — https://www.open-telekom-cloud.com/en/blog/benefits/openstack-the-standard-for-the-sovereign-public-cloud
- Consequence: Terraform/OpenTofu code written against the OpenStack provider transfers almost directly to these clouds, and OpenStack skills are valued at EU sovereign-cloud providers, telcos and research centres. **INFERRED**

## DevStack is not a long-lived cloud

- The DevStack FAQ says it is "targeted at developers and CI systems" and makes "many choices that are not appropriate for production systems". **VERIFIED** — https://docs.openstack.org/devstack/latest/faq.html
- A maintainer explained that DevStack is deliberately not built to survive reboots. **VERIFIED (mailing list)** — https://lists.openstack.org/pipermail/openstack-discuss/2019-April/005112.html
- Current DevStack uses systemd units, so some services may restart after a reboot. Network state (OVS/OVN bridges, the br-ex IP, LVM loop devices) usually breaks. **INFERRED**; that matches what happened in this lab, where DevStack broke after most reboots.
- DevStack has no upgrade path: moving to a new release means redeploying. **VERIFIED** — FAQ above.

## Deployment tools compared

| Tool | Model | Minimum resources | Fit for ~23 GB of OpenStack nodes | Source |
|---|---|---|---|---|
| **Kolla-Ansible** | Ansible deploys Docker containers; real `upgrade` command | AIO quickstart: 8 GB RAM, 40 GB disk, 2 NICs (VERIFIED) | Yes (chosen) | https://docs.openstack.org/kolla-ansible/latest/user/quickstart.html |
| OpenStack-Ansible (OSA) | Services in LXC containers (default) or on metal | AIO: 8 vCPU / 8 GB / 50 GB minimum, 16 GB recommended (VERIFIED) | Yes, equivalent to Kolla | https://docs.openstack.org/openstack-ansible/latest/user/aio/quickstart.html |
| Canonical Sunbeam | Control plane on Canonical Kubernetes with Juju charms; data plane as snaps | Single node: 4 cores, 16 GiB. Multi-node: 3 × 32 GiB (VERIFIED). Ubuntu only | No (too little guest RAM left) | https://canonical.com/openstack/docs/2026.1/reference/enterprise-requirements/ |
| OpenStack-Helm | Official project; OpenStack on Kubernetes via Helm | Legacy dev docs: 8–16 GB; CI used 32 GB runners (VERIFIED, snippets). Ubuntu hosts | Marginal | https://docs.openstack.org/openstack-helm/latest/readme.html |
| Red Hat RHOSO 18 | Control plane on OpenShift | 3 bare-metal OpenShift nodes, ≥16 GB each (VERIFIED, snippet) | Impossible | https://docs.redhat.com/en/documentation/red_hat_openstack_services_on_openshift/18.0/ |
| Mirantis MOSK 26.1 | Kubernetes-based | Management 3 × 64 GB, control plane 3+ × 128 GB (VERIFIED) | Impossible | https://docs.mirantis.com/mosk/26.1/ref-arch/reqs/mosk-hw-reqs.html |
| VEXXHOST Atmosphere | OpenStack-Helm + Ansible on Kubernetes | AIO ≥ 32 GB, 64 GB recommended (VERIFIED) | Impossible | https://vexxhost.github.io/atmosphere/quick-start.html |

**Trend.**
- Vendors are moving the control plane onto Kubernetes (Red Hat, Canonical, Mirantis, VEXXHOST). **VERIFIED**
- Self-deployed clouds are still dominated by Ansible-based tools. In the 2023 TC analysis of production users per project, **Kolla counted 59, OpenStack-Ansible 58, OpenStack-Helm 8**, and TripleO 23, which is now retired. **VERIFIED** — https://governance.openstack.org/tc/user_survey/analysis-2023.html
- No public per-tool breakdown exists for the 2024 or 2025 surveys. **VERIFIED (absence)** — https://openinfra.org/user-survey/

**Running Kolla inside Proxmox LXC containers** means Docker-in-LXC, plus nova-compute in a container that needs `/dev/kvm`. I found no production precedent. Proxmox itself recommends nesting inside QEMU VMs. Rejected. **VERIFIED/INFERRED** — https://pve.proxmox.com/wiki/Linux_Container

## Releases

Source: https://releases.openstack.org/, updated 2026-11-03. **VERIFIED**

| Release | Status (Nov 2026) |
|---|---|
| 2025.1 Epoxy | Unmaintained |
| 2025.2 Flamingo | Maintained |
| **2026.1 Gazpacho** | Maintained, **SLURP** |
| 2026.2 Hibiscus | Maintained (released 2026-09-30) |
| 2027.1 Indri | In development |

- **SLURP** releases (one per year, the `.1` releases) allow upgrades that skip the intermediate release. **VERIFIED** — https://governance.openstack.org/tc/resolutions/20220210-release-cadence-adjustment.html
- On PyPI, kolla-ansible 22.x is 2026.1 (22.2.0, 2026-09-08) and 23.0.0 is 2026.2. **VERIFIED** — https://pypi.org/project/kolla-ansible/#history
- Kolla-Ansible 2026.1 supports **Debian 13 (trixie)** hosts. **VERIFIED** — https://docs.openstack.org/kolla-ansible/2026.1/user/support-matrix.html

## OpenStack-on-Proxmox vs Proxmox-only (historical comparison)

- `bpg/proxmox` is very active (v0.120.0, 2026-11-02). It is simpler and has lower overhead, but has no cloud API, load balancer or block-storage integration for Kubernetes. **VERIFIED** — https://github.com/bpg/terraform-provider-proxmox/releases
- The project kept OpenStack for its cloud abstractions and later removed the Proxmox layer altogether. See [02](02-topology-and-nesting.md).
