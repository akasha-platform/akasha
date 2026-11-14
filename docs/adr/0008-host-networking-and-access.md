---
status: accepted
date: 2026-11-08
decision-makers: dhuy21
---

# Host networking, NAT boundary and Tailscale-only access

## Context and Problem Statement

The host sits on a campus network. Lab traffic needs Internet access but must never reach
the campus LAN. OpenStack needs separate management, overlay and provider networks.

## Decision Outcome

* Linux bridges defined on the host (ifupdown, managed by Ansible), not libvirt `<network>`
  objects (the provider replaces networks on any change; bridges mirror a physical fabric).
  * `br-transit` 10.255.255.0/29 — host ↔ OPNsense WAN (routed, no libvirt NAT)
  * `br-mgmt` 10.10.0.0/24 — management + APIs (VIP .100 internal; a separate external VIP
    .101 is proposed, one-vs-two VIPs is open — `docs/open-questions.md` B4)
  * `br-tun` 10.30.0.0/24, MTU 9000 — Geneve overlay
  * `br-ext` 10.20.0.0/24 — provider / floating IPs, unaddressed NICs on ctl and computes
* The host is the only NAT to the uplink (nftables masquerade) and drops lab → campus LAN.
* OPNsense (3 GB, official minimum) is the lab edge: routing, firewall, Unbound DNS for
  `akasha.internal` (ICANN-reserved), NTP for the lab.
* Remote access only through Tailscale; the host acts as subnet router for 10.10/24 and 10.20/24.
  The tailnet is the owner's personal tailnet: the owner approves the advertised routes and
  writes the ACLs (open question C5, answered on 2026-11-13).
* No libvirt nwfilter on bridge ports used by OVN; `br_netfilter` kept off; libvirt's
  nftables backend selected explicitly (`firewall_backend`), and the libvirt `default` network
  is not autostarted.
* Host addresses on `br-mgmt`: OPNsense .1, bastion .10, ctl .11, core .12, computes .21/.22.

The lab CIDRs, the `akasha.internal` zone and the 3 GB OPNsense sizing were confirmed
explicitly by the owner on 2026-11-09.

### Implementation (P1 step 4a, 2026-11-13)

Ansible role `host_network` (`playbooks/host.yml`, tag `network`):

* **Bridge tooling** (chosen by the owner on 2026-11-13 after the research in
  [research/09](../research/09-host-virtual-switching.md)): one Linux bridge per network,
  as ifupdown stanzas in `/etc/network/interfaces.d/akasha-bridges` (package `bridge-utils`,
  `bridge_ports none`, STP off, multicast snooping off). This is the pattern of the
  OpenStack-Ansible multi-node AIO lab. Considered and not chosen:
  * systemd-networkd (used by OpenStack-Ansible and Kayobe on Debian/Ubuntu; reloads bridges
    in place): a third network manager next to NetworkManager and Tailscale on the only
    access path of the host; its handling of foreign routes and rules was not verified.
  * One VLAN-aware bridge with a VLAN per network (closer to a physical trunk; libvirt ≥ 11.0
    supports VLAN tags on Linux bridges): more failure modes (a missing `vlan_filtering`
    silently removes isolation) for no isolation gain on one host.
  * NetworkManager keyfiles: NetworkManager would own the bridges of the lab.
* The uplink stays with NetworkManager (desktop session). NetworkManager's ifupdown plugin
  does **not** skip interfaces named `br*` (it only skips their ports, `nms-ifupdown-plugin.c`,
  NetworkManager 1.52), so the bridges are listed in `unmanaged-devices`
  (`/etc/NetworkManager/conf.d/90-akasha-unmanaged.conf`), written before any bridge exists.
* New bridges are brought up with `ifup`. `ifdown` deletes a bridge (`brctl delbr`) and
  detaches running VMs, so a changed definition of an existing bridge is never applied
  automatically: the role prints a warning and the runbook `host-network.md` describes the
  maintenance procedure.
* `br-transit` carries 10.255.255.1/29 and the routes to 10.10.0.0/24 and 10.20.0.0/24 via
  OPNsense (10.255.255.2). The other bridges have no host address.
* IPv6 is disabled on every lab bridge (`net.ipv6.conf.<bridge>.disable_ipv6`, applied by
  systemd-sysctl when the interface appears): without it the host gets a link-local address
  on `br-mgmt` and `br-ext`, reachable from lab VMs and floating IPs. IPv4 forwarding is on;
  IPv6 forwarding stays off (IPv4-only lab; forwarding would make the uplink ignore router
  advertisements).
* libvirt: `firewall_backend = "nftables"`; the `default` network is stopped and not
  autostarted, but kept defined for the powered-off Proxmox VM.
* Rules for later steps:
  * VM interfaces on `br-tun` must declare `mtu = 9000` (OpenTofu `mtu.size`): libvirt gives
    the tap the bridge MTU, but the guest NIC stays at 1500 unless the domain declares it.
    With `global_physnet_mtu = 9000` in Kolla, OVN tenant networks get 8942 (open question B2).
  * No libvirt `nwfilter` (`clean-traffic`) and no `macTableManager='libvirt'` on the
    OpenStack nodes' interfaces: OVN gateways and distributed floating IPs send frames from
    MACs and addresses the VM NIC does not own.
* The host firewall (nftables input policy, NAT, campus drop) is step 4b; Tailscale subnet
  routing is step 4c.

### Consequences

* Good, because the campus network is protected by an explicit drop rule.
* Bad, because three firewalls (host nftables, libvirt, Tailscale) share the netfilter hooks
  and must be tested together.

## More Information

[research/04-host-and-network.md](../research/04-host-and-network.md)
