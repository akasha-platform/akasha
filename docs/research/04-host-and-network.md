# 04 — Host and network

Researched: 2026-11-08. Re-check versions before use. For privacy, campus network ranges and the host's Tailscale address are not recorded here.

## Bridges on the host (libvirt, no Proxmox)

**Kolla interface roles** (**VERIFIED**: https://docs.openstack.org/kolla-ansible/latest/admin/production-architecture-guide.html):
- `api_interface` carries internal APIs, the database and RabbitMQ. It must not be reachable from outside.
- `tunnel_interface` carries Geneve traffic.
- `neutron_external_interface` is plugged into `br-ex`, so it has **no IP**.
- With distributed floating IPs, computes need the external interface too. **VERIFIED**: https://docs.openstack.org/kolla-ansible/latest/reference/networking/neutron.html

**Host bridges vs libvirt networks.** Use host bridges managed by ifupdown (Debian's default) through Ansible, rather than libvirt `<network>` objects. **INFERRED**. Reasons:
- **Production parity:** this mirrors production, where the switch fabric is not part of the VM lifecycle.
- **Provider behaviour:** since v0.9.8, the provider replaces a `libvirt_network` on any change other than `autostart`. **VERIFIED**: https://github.com/dmacvicar/terraform-provider-libvirt/releases
- **NAT path:** it keeps libvirt's NAT firewall out of the forwarding path.
- **libvirt features:** VLAN trunks on Linux bridges need libvirt ≥ 11.0, and trixie ships 11.3. **VERIFIED**: https://libvirt.org/formatnetwork.html, https://sources.debian.org/api/src/libvirt/

| Bridge | CIDR | MTU | Host IP | Members |
|---|---|---|---|---|
| br-transit | 10.255.255.0/29 | 1500 | .1 (routes lab nets, NAT to uplink) | OPNsense WAN .2 |
| br-mgmt (mgmt + API) | 10.10.0.0/24 | 1500 | none | OPNsense .1, bastion, core, ctl01, cmp01/02, internal + external VIPs |
| br-tun | 10.30.0.0/24 | **9000** | none | ctl01, cmp01, cmp02 |
| br-ext (provider/floating IPs) | 10.20.0.0/24 | 1500 | none | OPNsense .1 (gateway); ctl01/cmp NICs without IP; FIP pool .100–.250 |

**Per-VM IP plan (br-mgmt 10.10.0.0/24).** **INFERRED** (proposed plan, from the host-network research):

| Host | Address |
|---|---|
| OPNsense (LAN gateway) | .1 |
| bastion | .10 |
| os-ctl01 | .11 |
| core (OpenBao, versitygw) | .12 |
| os-cmp01 / os-cmp02 | .21 / .22 |
| Internal VIP (`kolla_internal_vip_address`) | .100 |
| External VIP (`kolla_external_vip_address`) | .101 |

**OPEN:** one VIP or two. Two VIPs mean two certificates (internal and external FQDN) and an OPNsense NAT/route rule for the external one; a single VIP is simpler. Not decided yet.

**MTU** (set via Kolla overrides):
- Neutron uses `global_physnet_mtu` and `[ml2] path_mtu`. **VERIFIED**: https://docs.openstack.org/neutron/latest/admin/config-mtu.html
- Geneve needs `max_header_size` 38. With `path_mtu` 9000, tenant networks get about 8942. **VERIFIED/INFERRED**: https://lists.launchpad.net/yahoo-eng-team/msg81975.html
- Keep the provider network at 1500.
- **OPEN:** whether tenant networks use the default 1442 (1500 underlay) or jumbo ~8942 (`path_mtu` 9000 on br-tun). The K8s pod MTU follows from that choice (see [05](05-kubernetes-on-openstack.md)).

**Do not filter MACs on lab bridges.**
- Never attach libvirt `clean-traffic` nwfilters to br-ext or br-tun ports. OVN routers and distributed FIPs send frames from MACs the VM does not own. **VERIFIED** (the filter exists) / **INFERRED** (the breakage): https://libvirt.org/formatnwfilter.html
- Keep `br_netfilter` off (`bridge-nf-call-iptables=0`).

## Routing, NAT and the campus LAN

- **Routed transit:**
  - Static routes on the host for the lab ranges via OPNsense.
  - A **single NAT** (nftables masquerade) on the host uplink.
  - An **explicit drop of lab traffic towards the campus LAN**.
  - OPNsense outbound NAT disabled, and "Block private networks" unchecked on its WAN. **INFERRED**
- **Why not libvirt's default NAT network:** its forward rules only allow traffic into its own subnet, so Tailscale → lab would be blocked. **INFERRED**
  - Destroy the libvirt `default` network, or at least do not autostart it, so its NAT rules do not interfere. **INFERRED**
- **nftables:** a packet must be accepted by *every* base chain on the same hook (libvirt's, Tailscale's and ours). **VERIFIED**: https://www.fedoraproject.org/wiki/Changes/LibvirtVirtualNetworkNFTables
- **Access is Tailscale only.**
  - The host is already a tailnet node. It acts as a **subnet router** with `tailscale set --advertise-routes=10.10.0.0/24,10.20.0.0/24`, routes approved in the admin console, and ACLs.
  - SNAT is on by default. **VERIFIED**: https://tailscale.com/kb/1019/subnets
  - Linux clients (the operator laptop) must run with `--accept-routes` to use the advertised routes. **VERIFIED**: https://tailscale.com/kb/1019/subnets
  - **OPEN:** who manages the tailnet ACLs and route approvals (personal tailnet vs another owner).
- **OPNsense Tailscale plugin:** it exists but sits behind double NAT, so keep it as a fallback. **VERIFIED**: https://tailscale.com/kb/1097/install-opnsense

## OPNsense as a KVM guest

- **Sizing:** minimum **3 GB RAM** ("reasonable" 4 GB, recommended 8 GB). **VERIFIED**: https://docs.opnsense.org/manual/hardware.html
- **Virtualization:** q35 or i440fx; the `os-qemu-guest-agent` plugin; disable hardware offloading. **VERIFIED**: https://docs.opnsense.org/manual/virtuals.html
- **vtnet TSO:** a FreeBSD regression exists (https://bugs.freebsd.org/bugzilla/show_bug.cgi?id=290773, **VERIFIED**). Start with offloads off and benchmark with iperf3.
- **Bootstrap as code:**
  - The installer's **configuration importer** reads `conf/config.xml` from a second disk. **VERIFIED**: https://docs.opnsense.org/manual/install.html
  - There is no official cloud image; a community qcow2 builder exists. **VERIFIED**: https://github.com/maurice-w/opnsense-vm-images
- **Ongoing config:**
  - `browningluke/opnsense` v0.26.0 is pre-1.0, "not recommended for production", and does not assign interfaces. **VERIFIED**: https://github.com/browningluke/terraform-provider-opnsense
  - Ansible alternative: `oxlorg.opnsense`. **VERIFIED**: https://github.com/O-X-L/ansible-opnsense
- **Config backup:** API `core/backup/download`, encrypted, because config.xml contains secrets. **VERIFIED**: https://docs.opnsense.org/development/api/core/core.html

## Core network services

- **DNS:** Unbound on OPNsense, zone **`akasha.internal`**. ICANN reserved `.internal` for private use (Resolution 2024.07.29.06). **VERIFIED**: https://circleid.com/posts/20240810-icann-reserves-.internal-domain-for-private-use
- **NTP:** Kolla no longer ships chrony (see [03](03-kolla-2026.1-findings.md)). Chain: host chrony → OPNsense → chrony in every VM. Clock skew breaks TLS validity, Keystone token expiry and log correlation. **INFERRED**
- **PKI:** issued by OpenBao (see [07](07-trust-and-data.md)). smallstep step-ca was evaluated and dropped once OpenBao was adopted. **VERIFIED** (step-ca features): https://smallstep.com/docs/step-ca/

## Base images

- **Debian 13 image:** `debian-13-genericcloud-amd64.qcow2` from a **dated** directory under https://cloud.debian.org/images/cloud/trixie/, checked against `SHA512SUMS`. **VERIFIED**
- **Kernel modules:** the cloud kernel config does not disable KVM, OVS or Geneve. Confirm with `modprobe kvm_intel openvswitch geneve` on the computes. **INFERRED**: https://sources.debian.org/src/linux/6.12.107-1/debian/config/
- **Access and baked images:** SSH keys only (`ssh_pwauth: false`). Use Packer (qemu builder 1.1.8) later for baked images, named `akasha-debian13-YYYYMMDD.N`. **VERIFIED** (Packer): https://developer.hashicorp.com/packer/integrations/hashicorp/qemu/latest/components/builder/qemu

## CPU pinning on the hybrid i7-14700

- **Find the core types:** P-core threads are in `/sys/devices/cpu_core/cpus` and E-cores in `/sys/devices/cpu_atom/cpus`; sibling pairs are in `topology/thread_siblings_list`. **VERIFIED**: https://gbmc.googlesource.com/linux/+/refs/heads/linux-6.4.y/tools/perf/Documentation/intel-hybrid.txt
- **Policy** (**INFERRED**):
  - `host-passthrough` everywhere.
  - ctl01 and the computes are pinned to sibling P-threads with a matching `threads=2` topology.
  - OPNsense, bastion, core and emulator threads are pinned to E-cores.
  - Check the result with `virsh dumpxml`, because issue #1344 reports `cpu.mode` being ignored on 0.9.7: https://github.com/dmacvicar/terraform-provider-libvirt/issues/1344
- **No hugepages:** RAM is fully committed, and hugepages are reserved statically. **INFERRED**
- **Nested virtualization checks at every level:** if L2 is slow, verify that `ept` and `enable_shadow_vmcs` are enabled (`/sys/module/kvm_intel/parameters/`). On Intel, migrating or save/restoring an L1 while an L2 runs needs kernel ≥ 5.3 and QEMU ≥ 4.2. **VERIFIED**: https://docs.kernel.org/virt/kvm/x86/running-nested-guests.html
- **Hybrid CPU limits:** KVM disables vPMU on hybrid hosts and cannot expose P/E differences to guests, hence the pinning. **VERIFIED**: https://lkml.iu.edu/hypermail/linux/kernel/2302.0/07482.html, https://www.phoronix.com/news/Intel-Core-Hybrid-Better-Virt

## Storage on the host

Measured: 477 GiB of unallocated NVMe space after the existing partitions.

- **Approved layout:** new partition → LVM VG `vg_akasha`:
  - `lv_images`: 320 GiB XFS mounted at `/var/lib/libvirt/akasha`, used as a libvirt `dir` pool of thin qcow2 volumes.
  - `lv_cinder`: 120 GiB raw LV passed to ctl01 as a block device. Inside the VM it becomes VG `cinder-volumes`, used with `enable_cinder_backend_lvm`.
  - About 37 GiB is left free for LVM snapshots.
- **Thin over-allocation (accepted):** planned virtual disk sizes are OPNsense 16 + bastion 20 + core 20 (+30 data disk) + ctl01 60 + cmp01 100 + cmp02 100 ≈ **346 G**, more than the 320 GiB of `lv_images`. Thin qcow2 only consumes what is written, so this is accepted; monitor pool usage (`virsh pool-info akasha`, `df`) and grow `lv_images` from the ~37 GiB VG free space if needed. **ESTIMATED**
- **Why a dir pool:** libvirt `logical` pools are thick, and thin pools were only requested in issue #1364. **VERIFIED**: https://github.com/dmacvicar/terraform-provider-libvirt/issues/1364
- **Cinder backend docs:** https://docs.openstack.org/kolla-ansible/latest/reference/storage/cinder-guide.html **VERIFIED**
- **LVM filter:** add a host `lvm.conf` `global_filter` so the host does not activate the guest's `cinder-volumes` VG. **INFERRED**
- **TRIM:** disk `driver.discard = "unmap"` plus `fstrim` in the guests. **VERIFIED** (schema).

## Backups for this layer

- **VM disks:** `virsh backup-begin` (push mode). **VERIFIED**: https://libvirt.org/kbase/live_full_disk_backup.html
- **Rebuild over restore:** rebuild ctl and cmp from code instead of restoring images.
- **What must be backed up:**
  - OPNsense config.
  - The bastion repository and configuration.
  - OpenBao raft snapshots.
  - OpenTofu state (the L0/bootstrap state cannot live in the in-lab S3 it creates; its location is OPEN, see [07](07-trust-and-data.md)).
  - MariaDB backups.
- **Destination:** off-site (see [07](07-trust-and-data.md)). The campus NFS share is **not used**, by policy.

## Host hardening

- **nftables (inet table):**
  - Input policy drop; allow lo, established, ICMP, and SSH on `tailscale0` only.
  - Forward: tailscale0 ↔ lab and lab → uplink, except the campus LAN.
  - libvirt ≥ 10.4 has an nftables backend. Set `firewall_backend = "nftables"` explicitly in `/etc/libvirt/network.conf` so libvirt, Tailscale and the host rules share one backend. **VERIFIED**: https://lists.libvirt.org/archives/list/users@lists.libvirt.org/thread/BF774GLLZN26XMEKAY5IRPZ6WISYXYQV
- **Operating the host (practical gotchas):**
  - The host locale is French: prefix commands whose output is parsed with `LC_ALL=C` (e.g. `LC_ALL=C virsh dominfo …`), otherwise field names such as `Max memory` are translated. **VERIFIED** (observed 2026-11-08)
  - Use `sudo virsh` or `virsh -c qemu:///system`; plain `virsh` as a user connects to `qemu:///session` and shows no system VMs or pools. **VERIFIED** (observed 2026-11-08)
- **Remote access:**
  - libvirt through the `libvirt` group and `qemu+ssh://` over Tailscale.
  - Consoles bound to 127.0.0.1, serial console as break-glass.
- **Updates:** unattended-upgrades for security updates only, with **no automatic reboot**, because a reboot takes the whole lab down. **VERIFIED**: https://wiki.debian.org/UnattendedUpgrades

## terraform-provider-libvirt (`dmacvicar/libvirt`) 0.9.9

**Version.** It is a full rewrite on the Plugin Framework, and v0.9.0 broke compatibility. **Pin `= 0.9.9`** (2026-08-30). **VERIFIED**: https://registry.terraform.io/providers/dmacvicar/libvirt/0.9.9/docs

**Schema.**
- Resources: `libvirt_domain`, `libvirt_volume`, `libvirt_network`, `libvirt_pool`, `libvirt_cloudinit_disk`. Data source: `libvirt_domain_interface_addresses`.
- Values and units are separate fields (`memory` + `memory_unit`).
- Disks: `source = { volume = {...} | file | block }`.
- Domain fields include `cpu_tune.vcpu_pin`, `emulator_pin`, `devices.mem_balloon.free_page_reporting`, `memory_backing.memory_nosharepages` and `memory_tune`.
- All **VERIFIED**: https://raw.githubusercontent.com/dmacvicar/terraform-provider-libvirt/v0.9.9/docs/resources/domain.md

**Gotchas** (all **VERIFIED**, from https://github.com/dmacvicar/terraform-provider-libvirt/issues):
- qcow2 disks need an explicit `driver = { name = "qemu", type = "qcow2" }` (#1329).
- The cloud-init ISO is staged in `os.TempDir()`, so a reboot shows spurious drift. Set a persistent `TMPDIR` (#1368, #1352).
- `user_data` is stored in state, so keep secrets out of it (#1362).
- Changing `backing_store` fails mid-apply (#1374).
- Volumes are immutable and cannot be resized (#1330, #1325).
- Networks are replaced on any change (0.9.8).

**Example `libvirt_domain`** (attribute names and nesting **VERIFIED** against v0.9.9 `docs/resources/domain.md`; interfaces have no `type` attribute — the source kind is selected by `source.bridge`; the pin values are **INFERRED** and must be adapted to the real core layout):

```hcl
resource "libvirt_domain" "cmp01" {
  name        = "os-cmp01"
  type        = "kvm"
  memory      = 7680
  memory_unit = "MiB"
  vcpu        = 6
  cpu = { mode = "host-passthrough", topology = { sockets = 1, cores = 3, threads = 2 } }
  cpu_tune = {
    vcpu_pin     = [for i in range(6) : { vcpu = i, cpu_set = tostring(4 + i) }]
    emulator_pin = { cpu_set = "20-27" }
  }
  os = { type = "hvm", type_arch = "x86_64", type_machine = "q35" }
  devices = {
    disks = [{
      source = { volume = { pool = "akasha", volume = libvirt_volume.cmp01.name } }
      target = { dev = "vda", bus = "virtio" }
      driver = { name = "qemu", type = "qcow2", discard = "unmap", detect_zeros = "unmap" }
    }]
    interfaces = [
      { model = { type = "virtio" }, source = { bridge = { bridge = "br-mgmt" } } },
      { model = { type = "virtio" }, source = { bridge = { bridge = "br-tun" } }, mtu = { size = 9000 } },
      { model = { type = "virtio" }, source = { bridge = { bridge = "br-ext" } } },
    ]
  }
  running   = true
  autostart = false # boot order is handled by a host systemd unit (see 03)
}
```
