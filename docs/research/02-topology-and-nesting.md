# 02 — Topology and nesting

Researched: 2026-11-08. All RAM numbers are **ESTIMATED** unless tagged otherwise. Re-measure after deployment.

## Starting point (measured 2026-11-08)

- **Physical host:** school-provided, Debian 13, Intel i7-14700 (8 P-cores with HT + 12 E-cores = 28 threads), 31 GiB RAM, NVMe 954 GiB (477 GiB unallocated), libvirt/KVM.
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

**Checks at every nesting level** (kernel docs) **VERIFIED** — https://docs.kernel.org/virt/kvm/x86/running-nested-guests.html
- If L2 guests are slow, check that `ept` and `enable_shadow_vmcs` are enabled (`/sys/module/kvm_intel/parameters/`) on the host and inside each compute.
- Migrating or save/restoring an L1 VM while its L2 guests run is supported on Intel from kernel 5.3 / QEMU 4.2; on AMD it is "undefined behavior". Relevant if the compute VMs themselves are ever live-migrated or snapshotted while running.

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

- **Red Hat:** "HCI" means the `ComputeHCI` role, which colocates Compute and Ceph OSD. The control plane stays on separate nodes. Red Hat warns that this colocation "risks resource contention between Ceph and Compute services, as neither are aware of each other's presence". **VERIFIED (snippet)** — https://docs.redhat.com/en/documentation/red_hat_openstack_platform/13/html-single/hyperconverged_infrastructure_guide/index
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

Inputs: tuned controller 7.5–8 GB; compute overhead 1.4–2.0 GB per node including the OS. **ESTIMATED** (basis in "Memory measurements behind the estimates" below). Disabling `cinder_backup` (on by default in 2026.1) saves about 0.15 GB on the controller. **ESTIMATED**

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

Caveats of the "adding hosts" procedure (relevant for `net01` and any future controller):
- `kolla-ansible bootstrap-servers --limit control` must include **all** controllers, because RabbitMQ needs host entries for every controller on every controller; then `pull --limit <new>` and `deploy --limit control`. **VERIFIED** — adding-hosts page above
- Routers and DHCP agents are **not rebalanced automatically**; move them by hand afterwards. **VERIFIED** — same page
- When adding controllers, the MariaDB role's `lookup_cluster` joins new nodes via SST and fails with "cluster exists but is stopped" if the cluster is down; make sure Galera is up and synced first. Going from 1 to 2 controllers gives no HA; go straight to 3. **VERIFIED** — kolla-ansible `roles/mariadb` (stable/2026.2), production architecture guide
- Kolla warns about the **LVM backend in multi-controller setups** (Launchpad bug 1571211): keep LVM-backed `cinder-volume` on a single `storage` host when controllers are added. **VERIFIED** — https://docs.openstack.org/kolla-ansible/2026.2/reference/storage/cinder-guide.html

**One availability zone per compute** (mirrors Red Hat DCN, where edge sites are compute-only under a central control plane; **VERIFIED (snippet)** — https://docs.redhat.com/en/documentation/red_hat_openstack_platform/17.1/html/deploying_a_distributed_compute_node_dcn_architecture/index):
- Nova: one host aggregate per compute with availability-zone metadata (e.g. `az-a`, `az-b`). **INFERRED** (standard Nova aggregate mechanism)
- Neutron/OVN: Kolla exposes `neutron_ovn_availability_zones`, which `setup-ovs.yml` writes into the chassis' `ovn-cms-options`. **VERIFIED** — KA/ansible/roles/ovn-controller/tasks/setup-ovs.yml (stable/2026.1)

**Controller OOM risk at 8 GB (with Octavia and Kolla Prometheus):**
- Measured evidence that 8 GB is tight:
  - A Kolla 2026.1 all-in-one used about **12.3 GB** right after deploy (6 vCPU, default workers, Heat and Horizon, no Cinder). **VERIFIED (third-party measurement)** — https://computingforgeeks.com/install-openstack-rocky-linux/
  - A lab OVN controller with separate computes: "It seems like about 10GB is what it needs". **VERIFIED (anecdote)** — https://github.com/EugenMayer/openstack-lab
  - Kolla maintainers saw the OOM killer on **8 GB CI nodes during Octavia tests** and split the nodesets into 8 GB / 16 GB. **VERIFIED** — https://meetings.opendev.org/irclogs/%23openstack-kolla/%23openstack-kolla.2025-08-22.log.html
- The 4–6.5 GB "tuned controller" figure is an estimate with workers=1 and no Heat/fluentd; Octavia (~0.3–0.5 GB) and Kolla's Prometheus server (~0.3–0.5 GB, off by default) come on top. **ESTIMATED**
- Mitigation: measure after deploy (`docker stats --no-stream`, `smem`), apply the low-RAM tuning from [03](03-kolla-2026.1-findings.md), defer Octavia if needed, and only then move RAM between controller and computes.

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
- C2 cannot hold the original 13 GB K3s flavour plan. Flavours must be trimmed to about 5.5 GB per compute (`k3s-server-1` 2.5 GB, `k3s-worker-1`/`k3s-worker-2` 3–3.5 GB, `k3s-ci-1` 2–2.5 GB; each compute carries one worker plus either the server or the CI node), and `reserved_host_memory_mb` set from measurement (expected ~1800–2600).
- **CI node as preemptible N+1 capacity** (runbook idea): if a compute fails, delete `k3s-ci-1` to free capacity on the surviving compute, then evacuate or recreate `k3s-server-1` there (restore from etcd snapshot if needed). Hard anti-affinity blocks this by design, so the runbook must remove the CI VM first or the pair must use soft anti-affinity.
- C3 is the only layout with real etcd quorum, but the platform would have to shrink by 60–70%.
- K3s VMs are not hypervisors, so live-migrating them between L1 computes should work. Avoid config drives (they break block migration) and give both computes an identical CPU model. **VERIFIED** for the config-drive limit — https://docs.openstack.org/nova/latest/admin/configuring-migrations.html

## Memory measurements behind the estimates

| Item | Figure | Tag | Source |
|---|---|---|---|
| Python services, anonymous RSS (DevStack, Oct 2026) | neutron-api 127 MB, neutron-rpc 126, neutron-ovn-agent 116, metadata agent 115, keystone 95, glance-api 92, placement 82; privsep daemons 0.3–0.45 GB per OVN AIO node | VERIFIED (third-party measurement) | https://www.madebymikal.com/chasing-openstack-memory-usage-the-memory-your-python-services-spend-on-code-they-never-run/ |
| nova-scheduler, single worker | 128 → 191 MiB over 6 h of churn; metadata agents 70–80 MiB | VERIFIED (measurement) | https://github.com/C5C3/cobaltcore/issues/1311 |
| RabbitMQ idle (older versions) | 85–300 MB | VERIFIED (measurement) | https://groups.google.com/g/rabbitmq-users/c/1rnpHZL5EaM |
| ovn-controller | ~115 MB RSS on a small cluster | VERIFIED (measurement) | https://bugzilla.redhat.com/show_bug.cgi?id=1905680 |
| Kolla upstream CI | AIO job on 16 GB; 3-node OVN job on 3 × 16 GB; `openstack_service_workers: 2` | VERIFIED | kolla-ansible `zuul.d/`, `tests/templates/globals-default.j2` |
| QEMU per-guest overhead, KubeVirt formula | 50 Mi + 8 Mi/vCPU + 8 Mi IOThread + 32 Mi video + RAM/512 → ~100–150 MiB for 2 vCPU / 4 GB | VERIFIED (documented formula) | https://github.com/kubevirt/kubevirt/blob/main/pkg/hypervisor/kvm/hypervisorbackend.go |
| QEMU per-guest overhead, Red Hat HCI calculator | 0.5 GB per guest ("based on measurement in test environment"), conservative | VERIFIED | https://github.com/RHsyseng/hci/blob/master/scripts/nova_mem_cpu_calc.py |
| Nested KVM guest, 2014 | ~280 MiB RES for 2 GB guests | VERIFIED (old measurement) | https://vbrownbag.com/2014/07/using-top-to-find-memory-overhead-for-qemukvm/ |

**Red Hat formula for reserved host memory:** reserved = total RAM − (number of VMs × (average VM size + per-VM overhead)) − RAM of host services. **INFERRED** (seen in search snippets only; page returned 403) — https://docs.redhat.com/ja/documentation/red_hat_openstack_platform/13/html/instances_and_images_guide/calculating-reserved-host-memory. akasha sets `reserved_host_memory_mb` from measurement (expected ~1800–2600) and keeps `ram_allocation_ratio = 1.0`.

## Minimum topologies vendors call "production"

| Vendor | Minimum | Source |
|---|---|---|
| Red Hat 17.1 | 3 Controllers; 1 Controller is for testing only | **VERIFIED (snippet)** — https://docs.redhat.com/en/documentation/red_hat_openstack_platform/17.1/html/installing_and_managing_red_hat_openstack_platform_with_director/assembly_planning-your-overcloud |
| Kolla | No node count, but the control group needs an odd number; "2 instances … do not provide (by default) any HA" | **VERIFIED** — https://docs.openstack.org/kolla-ansible/latest/admin/production-architecture-guide.html |
| Sunbeam | 3 × 32 GiB; single-node "has no resilience" | **VERIFIED** — enterprise-requirements link above |
| Mirantis | ≥ 3 control (128 GB) + ≥ 3 compute + Ceph 3 (5 recommended) | **VERIFIED** — MOSK link above |

**Conclusion:** 1 controller + N computes is a PoC/test topology for every vendor. akasha documents a production north-star (3 controllers, network nodes, Ceph) and explains the lab's deviations from it. **INFERRED**
