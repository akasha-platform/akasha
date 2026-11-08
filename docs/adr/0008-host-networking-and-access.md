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
  * `br-mgmt` 10.10.0.0/24 — management + APIs (VIPs .100 internal, .101 external)
  * `br-tun` 10.30.0.0/24, MTU 9000 — Geneve overlay
  * `br-ext` 10.20.0.0/24 — provider / floating IPs, unaddressed NICs on ctl and computes
* The host is the only NAT to the uplink (nftables masquerade) and drops lab → campus LAN.
* OPNsense (3 GB, official minimum) is the lab edge: routing, firewall, Unbound DNS for
  `akasha.internal` (ICANN-reserved), NTP for the lab.
* Remote access only through Tailscale; the host acts as subnet router for 10.10/24 and 10.20/24.
* No libvirt nwfilter on bridge ports used by OVN; `br_netfilter` kept off.

### Consequences

* Good, because the campus network is protected by an explicit drop rule.
* Bad, because three firewalls (host nftables, libvirt, Tailscale) share the netfilter hooks
  and must be tested together.

## More Information

[research/04-host-and-network.md](../research/04-host-and-network.md)
