# 09 — Host virtual switching

Researched: 2026-11-13 for P1 step 4a (ADR-0008). Re-check versions before use. Tags as in
[README](README.md): VERIFIED, INFERRED, ESTIMATED.

## How production clouds wire hypervisors

- Hypervisors get two NICs bonded (LACP 802.3ad across a pair of top-of-rack switches with
  MLAG/VLT, or active-backup), and 802.1Q trunks carry separate networks: management/API,
  storage, tenant overlay, external/provider, plus an out-of-band BMC network. **INFERRED**
  from the reference architectures below.
- OpenStack-Ansible reference: Linux bridges `br-mgmt`, `br-storage`, `br-vxlan` on VLAN
  sub-interfaces of a bond (`bond0.10` …), address on the bridge; a second bond for data-plane
  traffic in production; `br-vlan` no longer needed. OSA "does not mandate any specific method
  of configuring network interfaces" and offers a `systemd_networkd` role. **VERIFIED**:
  https://docs.openstack.org/openstack-ansible/latest/user/network-arch/example.html,
  https://docs.openstack.org/ansible-role-systemd_networkd/latest/user-guide.html
- Kolla-Ansible does not configure host networking: it requires `api_interface` with an
  address and a `neutron_external_interface` without an address, then creates `br-ex` (OVS)
  itself; computes need it only for distributed floating IPs or provider networks.
  **VERIFIED**: https://docs.openstack.org/kolla-ansible/latest/reference/networking/neutron.html,
  source `ansible/roles/openvswitch`, `roles/prechecks/tasks/port_checks.yml`.
- Kayobe (StackHPC, on top of Kolla) declares networks (`cidr`, `vlan`, `mtu`, `routes`) and
  configures hosts with systemd-networkd on Debian/Ubuntu (it removes netplan first) and
  ifcfg/nmstate on Rocky; it also configures the physical switches. **VERIFIED**:
  https://docs.openstack.org/kayobe/latest/configuration/reference/network.html
- Red Hat RHOSO 18: data-plane nodes use os-net-config (ifcfg or nmstate) with an OVS bridge
  `br-ex` and VLANs for internalapi, storage and tenant; control-plane workers use the NMState
  operator (`NodeNetworkConfigurationPolicy`, Linux bridge `ospbr`). TripleO is retired.
  **VERIFIED** (upstream repositories): https://github.com/openstack-k8s-operators/architecture,
  https://github.com/os-net-config/os-net-config, https://opendev.org/openstack/tripleo-docs
- Canonical (MAAS + netplan; Sunbeam traffic groups; external NIC "Unconfigured") and Mirantis
  MOSK (netplan "L2 templates", LACP bond + VLANs, floating network MTU 9000). **VERIFIED**:
  https://canonical.com/openstack/docs/latest/explanation/network-traffic-isolation-with-maas/,
  https://docs.mirantis.com/mosk/26.1/deploy/deploy-managed/add-bm-managed-cluster/create-l2/bonds-template.html
- Neutron recommends a 9000-byte underlay for most environments.
  **VERIFIED**: https://docs.openstack.org/neutron/latest/admin/config-mtu.html

## Virtual switch technologies

| Technology | Used by | Notes |
|---|---|---|
| Linux bridge | Proxmox VE (`vmbr0`, `bridge-vlan-aware`), OSA control plane, RHOSO control plane | No daemon; STP off and multicast snooping on by default (**VERIFIED**: https://docs.kernel.org/networking/bridge.html) |
| Open vSwitch | Nutanix AHV, OpenStack compute nodes (OVN), RHOSO `br-ex` | OpenFlow, mirroring, LACP; OVN runs **inside** the akasha OpenStack VMs |
| OVS-DPDK, SR-IOV, macvtap | NFV, special hardware | Need NIC hardware or a parent NIC; not applicable to internal lab networks (**INFERRED**) |
| VMware vSS/vDS, Hyper-V vSwitch | vSphere, Windows estates | LACP only on vDS (**VERIFIED**: Broadcom KB 324555) |

## Single-host labs that emulate several networks

- **OpenStack-Ansible multi-node AIO** (VMs on one KVM host): one host Linux bridge per
  network (`vm-br-eth1…6`), one vNIC per network per VM, provider bridge without an address,
  libvirt `default` network disabled — the pattern akasha follows. OSA AIO: one bridge per
  network with a dummy port at MTU 9000. **VERIFIED**: `openstack-ansible-ops/multi-node-aio`,
  `openstack-ansible/tests/roles/bootstrap-host`.
- Kayobe "a universe from nothing": a single flat bridge. TripleO quickstart (retired): few
  bridges, isolated networks as VLANs inside the VMs. Kolla CI: a VXLAN overlay between CI VMs
  and a bridge + veth for the external network. **VERIFIED** (repositories cloned 2026-11-13).

## One VLAN-aware bridge or N bridges

- libvirt supports `<vlan>` tags and trunks on standard Linux bridges since 11.0.0; the
  Terraform provider `dmacvicar/libvirt` 0.9.9 exposes `interfaces.vlan`. **VERIFIED**:
  https://libvirt.org/formatnetwork.html, provider `docs/resources/domain.md`.
- libvirt programs per-port VLANs but does not enable `vlan_filtering` on the bridge itself;
  without it the tags isolate nothing. **INFERRED** from `src/util/virnetdevbridge.c`.
- Mixed MTUs on one bridge work because the kernel checks the egress port MTU.
  **VERIFIED**: `net/bridge/br_forward.c` (Linux 6.12).
- Decision: N bridges (ADR-0008); a VLAN trunk stays a possible later ADR.

## Configuration tools

| Tool | Used by | Rollback | Reload in place |
|---|---|---|---|
| ifupdown 0.8 | Debian classic | none | no: `ifdown` runs `brctl delbr` (**VERIFIED**, bridge-utils hook) |
| ifupdown2 | Proxmox VE ≥ 7.0 (replaces ifupdown in Debian) | none | `ifreload` |
| systemd-networkd | OSA role, Kayobe on Debian/Ubuntu | none | `networkctl reload` |
| NetworkManager + nmstate | RHEL, OpenShift NMState operator | checkpoint, 60 s default | yes; nmstate is not packaged in Debian (**VERIFIED**) |
| netplan | Ubuntu, Canonical, Mirantis | `netplan try`, 120 s | `netplan apply` |

Sources: https://manpages.debian.org/trixie/ifupdown2/ifreload.8.en.html,
https://www.freedesktop.org/software/systemd/man/latest/networkctl.html,
https://github.com/nmstate/nmstate, https://netplan.readthedocs.io/en/stable/netplan-try/

## NetworkManager next to ifupdown (insa)

- NetworkManager's ifupdown plugin treats an `iface` named `br*` as a bridge, adds only its
  ports to the unmanaged list and skips the bridge itself; with `bridge_ports none` nothing is
  added. **VERIFIED**: `src/core/settings/plugins/ifupdown/nms-ifupdown-plugin.c`
  (NetworkManager 1.52.0). The bridges are therefore listed in `[keyfile] unmanaged-devices`,
  which "cannot be overruled by using the API". **VERIFIED**:
  https://networkmanager.dev/docs/api/latest/NetworkManager.conf.html
- ifupdown order for one interface: `pre-up` options → `if-pre-up.d` (bridge-utils creates
  the bridge here) → method (MTU, address, link up) → `up` options → `if-up.d`. **VERIFIED**:
  ifupdown 0.8.44 `execute.c`, `inet.defn`.
- `networking.service` runs `ifup -a` before `network.target`; libvirtd and libvirt-guests
  start after `network.target`. **VERIFIED**: Debian `networking.service`, libvirt 11.3 units.
- bridge-utils has no multicast snooping option; the role uses
  `up ip link set dev <bridge> type bridge mcast_snooping 0`. **VERIFIED**: bridge-utils
  1.7.1-4 `debian/ifupdown.sh`.

## MTU on the overlay bridge

- libvirt sets a new tap to the bridge MTU when the domain gives none, but passes `host_mtu`
  to QEMU only when `<mtu>` is set: the guest NIC needs `<mtu size='9000'/>`. **VERIFIED**:
  `src/util/virnetdevtap.c`, `src/qemu/qemu_command.c`.
- The kernel lowers a bridge to the smallest port MTU unless the MTU was set by the user
  (`ip link set … mtu`); ifupdown sets it that way. **VERIFIED** (`br_if.c`, Linux 6.12) /
  **INFERRED** (ifupdown path). Checked on the host with a temporary tap (runbook).
- Tenant MTU = 9000 − 20 − 38 (Geneve, Kolla `max_header_size`) = 8942. **VERIFIED**:
  Neutron `type_geneve.py`, Kolla `ml2_conf.ini.j2`.
