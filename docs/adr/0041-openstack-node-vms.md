---
status: accepted
date: 2026-11-24
decision-makers: dhuy21
---

# OpenStack node VMs: dedicated sibling P-cores, three NICs, a raw LV for Cinder

## Context and Problem Statement

Step 6d creates the OpenStack nodes that Kolla-Ansible configures in P2.
[ADR-0006](0006-openstack-topology-v1b.md) and [ADR-0030](0030-ram-budget.md) fix:
* the nodes: `os-ctl01` (4 vCPU, 8 GiB), `os-cmp01` and `os-cmp02` (6 vCPU, 7.6 GiB each);
* the networks: `br-mgmt`, `br-tun` (MTU 9000) and `br-ext`;
* Cinder on `lv_cinder`, a raw 120 GiB LV of the host's `vg_akasha` that the role
  `host_storage` created in step 4 (ADR-0009).

How the VMs use the CPUs, the NICs and that LV was open.

Facts read on `insa` on 2026-11-24:
* **CPUs.** The P-core threads are 0–15, in sibling pairs `0-1`, `2-3` … `14-15`; the E-cores
  are 16–27.
* **Nested virtualisation.** `kvm_intel` has `nested=Y`, `ept=Y` and `enable_shadow_vmcs=Y`.
* **`br-tun`** has MTU 9000.
* **`lv_cinder`** is active, not open, and blank (`blkid -p` exit code 2).

## Decision Drivers

* No OpenStack node competes with another for CPU, and the guests know which vCPUs share a
  core.
* Nothing changes on `insa` beyond attaching akasha's own LV (ADR-0027).
* Every VM, the existing ones included, is still built by the same module, with an empty
  plan for those that do not use the new options.

## Considered Options

* **CPU:**
  * a dedicated block of sibling P-core threads per VM, pinned 1:1, with a guest topology of
    two threads per core and the emulator threads on the E-cores (research note 04);
  * the three VMs floating over all 16 P-core threads.
* **Host firewall on the nodes:** now (SSH only), or designed together with Kolla in P2.

## Decision Outcome

Chosen by the owner on 2026-11-24: dedicated 1:1 blocks with `threads=2`; the nodes' host
firewall in P2; 6d split into 6d-1 (the VMs) and 6d-2 (the RAM gate).

* **The module `libvirt-vm`** takes four optional inputs. VMs that leave them unset are
  unchanged.
  * `vcpu_cpus`: one host CPU per vCPU, pinned 1:1;
  * `emulator_cpu_set`;
  * `cpu_threads`: the guest topology, one socket of `vcpus / threads` cores;
  * `block_disk_path`: a raw block device of the host, attached after the other disks with
    `raw`, `cache=none`, `io=native` and `discard=unmap`.
* **The nodes** (`openstack.tf`, one `for_each` module):

  | VM | vCPU → host threads | RAM (MiB) | Disks |
  |---|---|---|---|
  | os-ctl01 | 0–3 | 8 192 | 60 G overlay, `/dev/vg_akasha/lv_cinder` as `vdb` |
  | os-cmp01 | 4–9 | 7 782 | 100 G overlay |
  | os-cmp02 | 10–15 | 7 782 | 100 G overlay |

  * The emulator threads run on the E-cores, 16–27.
  * Each node has three NICs:
    * `mgmt` on `br-mgmt` (10.10.0.x; the router as gateway and DNS server);
    * `tun` on `br-tun` (10.30.0.x, MTU 9000, no gateway);
    * `ext` on `br-ext`: up, but with no IPv4 or IPv6 address, for OVN's provider bridge.
  * MAC addresses end with the node's last address byte in hexadecimal, and their fourth
    byte names the network (`0a` mgmt, `1e` tun, `14` ext).
* **`lv_cinder`** stays a volume of the host's LVM, created by Ansible (`host_storage`) and
  never managed by OpenTofu. It carries the serial `lv_cinder`, so Kolla can name it
  `/dev/disk/by-id/virtio-lv_cinder` whatever the disk order. Destroying the controller
  detaches it without deleting it.
* **Ansible.** The group `openstack_nodes` runs `vm_base` and `lab_client`, then the role
  `os_node`, which only reads and checks:
  * the three NICs;
  * the guest topology;
  * on the computes, `/dev/kvm`, `vmx` and `kvm_intel`;
  * on the controller, a 120 GiB `vdb` with serial `lv_cinder`, blank before P2, or an LVM
    physical volume once Cinder has created its volume group on it.
* **No host firewall yet.** Until P2 the nodes run only the cloud image's services: sshd,
  and systemd-resolved's LLMNR (port 5355, verified in step 6d-1). Kolla opens many ports
  between them, and Docker interacts with nftables, so the nodes' firewall is designed with
  Kolla.

### Consequences

* Good, because each node owns its cores, and the guests' schedulers see the real sibling
  pairs.
* Good, because the existing VMs and their plans are untouched, and `lv_cinder` cannot be
  deleted by OpenTofu.
* Bad, because the 16 P-core threads are fully assigned. The school desktop and the host
  share them with the nodes whenever the nodes are busy, while the E-cores hold the small
  VMs and the emulator threads.
* Bad, because the nodes have no host firewall before P2. They sit on `br-mgmt` behind the
  router, with no service of akasha listening.
* Bad, because rebuilding the controller after P2 orphans Cinder's volume group: it survives on
  `lv_cinder`, but Cinder's database lived on the destroyed root disk. The volumes are then
  recovered or wiped on purpose (runbook `opentofu-l0.md`).

### Confirmation

Step 6d-1:
* the plan adds the three nodes (12 resources) and changes nothing else; a second plan is
  empty;
* `virsh vcpupin` and `virsh dumpxml` show the 1:1 pins, the emulator on 16–27, `threads=2`,
  and `lv_cinder` as a raw `vdb` with its serial; in each guest, `lscpu -e=CPU,CORE` shows
  sibling vCPUs sharing a core;
* on `insa`: no AppArmor denial, and `pvs -a` still shows the host's one physical volume;
* the playbook's checks pass, and a second run reports `changed=0`.

### Implementation (2026-11-24)

Applied from PR #71.

* **OpenTofu.** The plan added the 12 resources of `module.os_node` and changed nothing else,
  and a second plan was empty.
* **Host checks before and after.**
  * Before: `linux2024` was off; `lv_cinder` was neither open nor carrying a signature; the
    akasha slice's cpuset was `0-27`.
  * After: no AppArmor denial, and still one physical volume on `insa`.
* **`lv_cinder` on the host.** It stays `root:disk` while the controller runs, and the guest
  uses it. libvirt gives QEMU a private `/dev` in its own mount namespace and changes the
  owner there, not on the host (INFERRED from libvirt's default `namespaces`).
* **Pinning and topology.** `virsh vcpupin` shows vCPUs 0–3 on host CPUs 0–3, 4–9 and 10–15
  for the nodes, and the emulator pin is `16-27`. The topology is `cores=2 threads=2` (ctl)
  and `cores=3 threads=2` (computes). In `os-cmp01`, `lscpu -e` pairs vCPUs (0,1), (2,3) and
  (4,5) on the same core.
* **Host keys** matched the serial logs.
* **Ansible.** The playbook passed every check on the three nodes (`os_node`: the NICs,
  nested virtualisation on the computes, and the blank 120 GiB `vdb` with serial `lv_cinder`
  on the controller), and a second run reported `changed=0`.
* **Time.** The host clock read through ptp_kvm was −8.5 ms from the nodes' clock.
* **Listening on a node** (`ss`, `os-cmp01`): sshd on 22, and systemd-resolved's LLMNR on 5355
  (TCP and UDP, all addresses). On the other VMs the host firewall drops it. On the nodes it
  is open until P2, where turning LLMNR off is proposed together with their firewall.

## More Information

* ADR-0005 (pinning to P-cores), ADR-0006 (topology), ADR-0009 (disk layout), ADR-0033 (VM
  conventions), ADR-0038 (the module's optional disks).
* Research note 04, "CPU pinning on the hybrid i7-14700".
* An independent review (2026-11-24) found no blocker. Its findings were fixed before
  anything ran:
  * Intel's `vmx flags` line doubled the vmx count;
  * the permanent "blank" check would have broken after P2;
  * the block disk had no serial;
  * the plan lacked pre- and post-apply checks and a memory stop rule.
