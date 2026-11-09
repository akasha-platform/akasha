# 02 — Topology and nesting

Researched: 2026-11-08. All RAM numbers are **ESTIMATED** unless tagged otherwise. Re-measure after deployment.

## Starting point (measured 2026-11-08)

- **Physical host:** school-provided, Debian 13, Intel i7-14700 (8 P-cores with HT + 12 E-cores = 28 threads), 31 GiB RAM, NVMe 954 GB, libvirt/KVM.
- **Previous stack:** a Proxmox VE VM (23 GiB, 16 vCPU) inside libvirt, then DevStack (18 GiB) inside Proxmox, then Nova guests.
- **Nested virtualization:** enabled at every level (`nested=Y`, `host-passthrough`). Nova uses `virt_type=kvm`, but DevStack defaults to `cpu_mode=custom`, `Nehalem`, which has no AVX.

## Nesting depth: why the Proxmox layer was removed

| Evidence | Tag | Source |
|---|---|---|
| RHEL 10: L2 VMs as hypervisors and L3 guests "has not been properly tested and is not expected to work" | VERIFIED (snippet) | https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/10/html/configuring_and_managing_linux_virtual_machines/creating-nested-virtual-machines |
| RHEL 7: L3 guests are "not supported" | VERIFIED (snippet) | https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/7/html/virtualization_deployment_and_administration_guide/sect-nested_virt_restrictions |
| Red Hat "Inception" test, 2 vCPU / 4 GB at each level:<br>• shell loop: L2 +6% vs L1, **L3 +140% vs L2**<br>• kickstart install: 221 s (L1) / 370 s (L2) / **1297 s (L3)** | VERIFIED | https://www.redhat.com/en/blog/inception-how-usable-are-nested-kvm-guests |
| Turtles (OSDI'10): L2 costs about 6–8% over single-level virtualization; VM exits multiply at each level | VERIFIED | https://www.usenix.org/conference/osdi10/turtles-project-design-and-implementation-nested-virtualization |
| Nova: guests that themselves run nested guests fail to live-migrate | VERIFIED | https://docs.openstack.org/nova/latest/admin/configuration/hypervisor-kvm.html |
| Hybrid P/E CPUs: KVM cannot expose the core types to guests; vPMU is disabled on hybrid hosts | VERIFIED | https://www.phoronix.com/news/Intel-Core-Hybrid-Better-Virt , https://lkml.iu.edu/hypermail/linux/kernel/2302.0/07482.html |

With Proxmox in the chain, the K3s VMs would be L3 guests: host → Proxmox → compute → K3s. Without it they are L2: host → compute → K3s. That matches production, where OpenStack computes are bare metal and tenant VMs sit one level below. **INFERRED**

## Host layouts compared

The host keeps about 3 GB. Proxmox costs about 1.5 GB (official recommendation is 2 GB). OPNsense minimum is 3 GB. **VERIFIED** for the two minimums — https://pve.proxmox.com/pve-docs/chapter-pve-installation.html , https://docs.opnsense.org/manual/hardware.html

| Layout | Composition | K3s guest RAM | K3s nesting level |
|---|---|---|---|
| A | Proxmox 27 GB → OPNsense 2 + ctl 10 + cmp 6.5 ×2 | ~9.0–10.2 GB | L3 |
| A′ | Proxmox 28 GB → OPNsense 2 + ctl 8 + cmp 8 ×2 | ~12.0–13.2 GB | L3 |
| C | Proxmox → 1 converged ctl+cmp 13 + cmp 11 | ~13.5–17.2 GB (high OOM risk) | L3 |
| **F (chosen)** | No Proxmox: libvirt → OPNsense 3, bastion 1, core 0.75, ctl 8, cmp ~7.6 ×2 | ~10–12 GB (see C2 below) | **L2** |

- The A-family rows assume OPNsense at 2 GB, which is below its official minimum; that is another point against them.
- Layout F replaces the `bpg/proxmox` provider with `dmacvicar/libvirt`. See [04](04-host-and-network.md).

## "Hyperconverged": correcting a misconception

- **Red Hat:** "HCI" means the `ComputeHCI` role, which colocates Compute and Ceph OSD. The control plane stays on separate nodes. **VERIFIED (snippet)** — https://docs.redhat.com/en/documentation/red_hat_openstack_platform/13/html-single/hyperconverged_infrastructure_guide/index
- **Mirantis:** dedicated control plane nodes. Colocating the control plane is a "technical preview… testing and evaluation only". **VERIFIED** — https://docs.mirantis.com/mos/latest/ref-arch/reqs/mosk-hw-reqs.html
- **Converged 3-node clouds**, where each node runs control + compute (+ storage), do exist for small sites:
  - OpenMetal sells "three hyper-converged control plane nodes" deployed with Kolla-Ansible. **VERIFIED** — https://openmetal.io/docs/manuals/operators-manual/day-1/intro-to-openmetal-private-cloud
  - Sunbeam's HA tutorial joins 3 nodes with `--role control --role compute --role storage`. **VERIFIED** — https://ubuntu.com/tutorials/scale-the-deployment-out-for-full-high-availability
  - Sunbeam forbids the **network and compute roles on the same node**. **VERIFIED** — https://canonical.com/openstack/docs/latest/explanation/architecture/
- **Why the converged 3-node layout was rejected here:**
  - Kolla's upstream CI runs its 3-node OVN job on **3 × 16 GB** nodes. **VERIFIED** — kolla-ansible `zuul.d`
  - Sunbeam needs **32 GiB per node**, and its converged role alone needs ≥ 11 GiB of control plane. **VERIFIED** — https://canonical.com/openstack/docs/2026.1/reference/enterprise-requirements/
  - At about 8.3 GB per node, only ~3–6 GB of guest RAM would remain. **ESTIMATED**
  - HA would be cosmetic, because all three nodes share one physical host.

## Node-role variants with ~23.25 GB for OpenStack nodes

Inputs: tuned controller 7.5–8 GB; compute overhead 1.4–2.0 GB per node including the OS. **ESTIMATED**

| Variant | Guest RAM | What it mirrors | Verdict |
|---|---|---|---|
| V1: 1 ctl (+net+storage) + 2 cmp | 11.25–12.95 | Kolla's default collapsed layout; Red Hat PoC | Viable |
| **V1b: V1 + computes as OVN gateway chassis** | same as V1 | OSA "collapsed compute/gateway", HA_Chassis_Group failover | **Chosen** |
| V2: + dedicated network node (~1.25–1.5 GB) | 10.05–12.0 | Red Hat Networker role | Fails the K3s budget |
| V3: + dedicated storage node (~1.0–1.25 GB) | 10.4–12.35 | Storage split, iSCSI data path | Fails |
| V4: ctl + net + storage + 2 cmp | 9.2–11.4 | Kolla's full five-role layout | Fails |
| V5: 1 ctl + 1 large cmp | 13.25–14.35 | AIO-style PoC | Fits, but teaches least |

**What a network node runs in Kolla 2026.1** (all **VERIFIED** in `ansible/inventory/multinode`):
- `loadbalancer` (haproxy, keepalived, proxysql) is a child of `network`.
- `ovn-controller-network` hosts get `enable-chassis-as-gw` (`roles/ovn-controller/tasks/setup-ovs.yml`).
- The OVN NB/SB databases and northd stay on `control`.

**Gateway placement:**
- With `neutron_ovn_distributed_fip`, floating-IP traffic leaves directly from the computes. Only SNAT and router-gateway traffic still use the gateway chassis. **VERIFIED** — https://docs.openstack.org/neutron/2026.1/admin/ovn/routing.html
- OSA documents collapsed network/gateway, collapsed compute/gateway, and standalone gateway nodes. It says routers "may not automatically migrate" with only two chassis, and that three or more are more reliable. **VERIFIED** — https://docs.openstack.org/openstack-ansible-os_neutron/2026.1/app-ovn.html
- Mirantis puts gateways on control-plane nodes by default. **VERIFIED** — MOSK link above.
- Red Hat OSP 17.1 runs OVN on Controllers by default, with an optional Networker role. **VERIFIED (snippet)**
- **V1b gateway chassis = ctl01 + cmp01 + cmp02**, i.e. 3 chassis. **INFERRED**: use a custom `[ovn-controller-network]` group and keep `[loadbalancer]` on the controller.

**Plan for a dedicated network node:** add `net01` later through Kolla's "adding hosts" procedure, and only if the measured spare RAM is at least 1.5 GB. **VERIFIED** procedure — https://docs.openstack.org/kolla-ansible/2026.2/user/adding-and-removing-hosts.html

## Compute count and failure headroom

**Principles:**
- Google SRE N+2: serve peak "while the largest 2 instances are unavailable". **VERIFIED** — https://sre.google/sre-book/service-best-practices/
- Kubernetes: "select at least three failure zones" for the control plane. **VERIFIED** — https://kubernetes.io/docs/setup/best-practices/multiple-zones/
- etcd fault tolerance is 0 for 1 or 2 members and 1 for 3 members. **VERIFIED** — https://etcd.io/docs/v3.5/faq/
- **Current Nova defaults:** `initial_cpu_allocation_ratio=4.0`, `initial_ram_allocation_ratio=1.0`, `reserved_host_memory_mb=512`. The arch guide's 16:1 / 1.5:1 figures are outdated. **VERIFIED** — https://docs.openstack.org/nova/latest/configuration/config.html

| Layout | Net guest RAM | N+1 usable | etcd HA across hypervisors | Live migration / evacuate |
|---|---|---|---|---|
| C1: ctl 8 + 1 cmp 15.25 | 12.05–13.25 | 0% | No | None |
| **C2: ctl 8 + 2 cmp ~7.6 (chosen)** | **10.05–11.85** (12.35 with ctl 7.5) | 50% | No (2+1 split loses quorum) | Yes / yes, but a hard anti-affinity pair cannot be evacuated: "No valid host" |
| C3: ctl 8 + 3 cmp ~5.1 | 7.45–10.15 | 67% | **Yes** | Yes / yes |

**Consequences** (all **INFERRED**):
- C2 cannot hold the original 13 GB K3s flavour plan. Flavours must be trimmed to about 5.5 GB per compute, and `reserved_host_memory_mb` raised to the measured overhead (≈1.8–2.6 GB).
- C3 is the only layout with real etcd quorum, but the platform would have to shrink by 60–70%.
- K3s VMs are not hypervisors, so live-migrating them between L1 computes should work. Avoid config drives (they break block migration) and give both computes an identical CPU model. **VERIFIED** for the config-drive limit — https://docs.openstack.org/nova/latest/admin/configuring-migrations.html

## Minimum topologies vendors call "production"

| Vendor | Minimum | Source |
|---|---|---|
| Red Hat 17.1 | 3 Controllers; 1 Controller is for testing only | **VERIFIED (snippet)** — https://docs.redhat.com/en/documentation/red_hat_openstack_platform/17.1/html/installing_and_managing_red_hat_openstack_platform_with_director/assembly_planning-your-overcloud |
| Kolla | No node count, but the control group needs an odd number; "2 instances … do not provide (by default) any HA" | **VERIFIED** — https://docs.openstack.org/kolla-ansible/latest/admin/production-architecture-guide.html |
| Sunbeam | 3 × 32 GiB; single-node "has no resilience" | **VERIFIED** — enterprise-requirements link above |
| Mirantis | ≥ 3 control (128 GB) + ≥ 3 compute + Ceph 3 (5 recommended) | **VERIFIED** — MOSK link above |

**Conclusion:** 1 controller + N computes is a PoC/test topology for every vendor. akasha documents a production north-star (3 controllers, network nodes, Ceph) and explains the lab's deviations from it. **INFERRED**
