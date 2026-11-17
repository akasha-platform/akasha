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

### Confirmation (step 4a)

On 2026-11-14, `playbooks/host.yml --tags network` (role `host_network`, PR #26):

* Read-only pre-check: monolithic `libvirtd` (modular daemons inactive); `linux2024` attached
  to the libvirt `default` network (runbook: start that network before the VM); no file in
  `/etc/NetworkManager/conf.d/`; a pre-existing `99-disable-ipv6.conf` with no effect (open
  question B9).
* Dry run (`--check --diff`) printed the three new files and the `firewall_backend` line;
  `command` tasks are reported as skipped in check mode.
* Real run `failed=0`, the four bridges created by `ifup`; second run `changed=0`.
* On the host: the four bridges are `UP` with `NO-CARRIER` (no port yet); `br-transit` has
  10.255.255.1/29 and both routes via 10.255.255.2 (`linkdown` until OPNsense exists);
  NetworkManager reports the bridges as unmanaged and `eno1` as connected; MTU 1500/1500/9000/1500,
  no IPv6 address, multicast snooping 0; `ip_forward=1`; `default` network inactive and not
  autostarted; `firewall_backend = "nftables"`; libvirtd, NetworkManager and tailscaled
  active; SSH over Tailscale kept.
* `br-tun` stays at MTU 9000 after a tap joins and leaves it (runbook test).
* The checks run with `LC_ALL=C` (ADR-0026): the host locale is French and `nmcli` prints
  `non-géré` otherwise.
* Not yet checked: the same state after a host reboot (open question A17).

### Implementation (P1 step 4b)

Ansible role `host_firewall` (`playbooks/host.yml`, tag `firewall`), designed under
[ADR-0027](0027-guest-on-the-school-host.md) and reviewed twice by an independent agent:

* **Scope:** the nftables table `inet akasha` (`/etc/akasha/firewall.nft`) matches only packets
  that enter or leave the four lab bridges (named explicitly, not `br-*`, which Docker also
  uses). Its base chains have `policy accept`, so the host's own traffic (SSH, NFS, desktop,
  Tailscale, libvirt's `virbr0`) meets no akasha rule. The default-deny `input` chain of
  research/04 was **not adopted**: it would have changed the school's machine (lockout risk,
  NFS, IT access), chosen by the owner on 2026-11-15. Step 4d widens the scope to routed
  packets towards the lab ranges (still akasha's own ranges, ADR-0027): they may only leave
  through `br-transit`. Residual risk accepted by the owner (2026-11-17): the host's own
  processes are not matched (output hook), so while the routes via `br-transit` are missing
  they could still reach a lab range through `eno1`; nothing on the host talks to the lab
  today (Ansible and OpenTofu run from the laptop). Revisit if a host service needs the lab.
* **Rules:** the lab may only ping the transit address of the host; only `br-transit` may
  route; sources outside the lab ranges are dropped; routed lab traffic leaves through `eno1`
  only towards public destinations (RFC 6890 special ranges and the campus's public prefixes,
  given at run time from a private file, are dropped); `ct state invalid` is dropped first
  (such packets would leave without NAT); IPv6 is dropped; tailnet → 10.10/24 and 10.20/24 is
  allowed; lab sources are masqueraded on `eno1`.
* **Second layer:** `net.ipv4.conf.<bridge>.forwarding = 0` (and `accept_redirects = 0`) on
  `br-mgmt`, `br-tun` and `br-ext` (role `host_network`): the kernel drops routed packets from
  these bridges before netfilter.
* **Unit** `akasha-firewall.service`: loads the file before `network-pre.target` like Debian's
  `nftables.service`, but never flushes the ruleset and has no `ExecStop`; `TimeoutStartSec=30s`
  so a stuck `nft` cannot hold back NetworkManager, networking and tailscaled. Reload replaces
  the table atomically.
* **Residual risk accepted by the owner** (simple version, no coupling of the bridges or
  libvirt to the firewall): if the table is missing (load failure at boot, `nft flush
  ruleset`, enabling Debian's `nftables.service`), `br-transit` routes without filter or NAT.
  The runbook checks the table after every reboot, and the lab router will not autostart
  before that check (step 6).
* Egress from the campus (checked 2026-11-16): public DNS (UDP 53) and HTTPS work; NTP (UDP 123)
  to public servers is blocked — the lab's time source is open question C4.
* For step 4c: Tailscale masquerades tailnet → lab flows (`ts-postrouting`), so the lab router
  sees the source 10.255.255.1.

### Confirmation (step 4b)

On 2026-11-16, `playbooks/host.yml --tags network,firewall` with the campus's public /24 from
the private file:

* Read-only pre-check: nft 1.1.3; leftover libvirt chains `LIBVIRT_FWX`/`LIBVIRT_FWI` empty;
  `rp_filter` all=0, default=2; the campus NFS server and gateway are in private ranges; the
  campus's public egress address belongs to its own RENATER /24 (whois), blocked from the lab.
* Two independent reviews of the plan before coding; the dry run checked the rendered rules
  with the host's `nft -c`.
* Real run `failed=0`; second run `changed=0`.
* Host traffic unchanged: same failed units before and after, NFS still mounted, Tailscale,
  NetworkManager and the firewall unit active, SSH over Tailscale kept.
* Fake lab VM (network namespace on `br-transit`): TCP 443 to the Internet works and is
  masqueraded; ping of the transit address works; the campus gateway, the campus public /24,
  the host's uplink address and the host's SSH (uplink and transit addresses) are blocked, with
  the `blocked_nets` and `lab_to_host` drop counters increasing. A namespace on `br-mgmt` using
  the host as router is dropped by the kernel (`IpInAddrErrors`), before netfilter.
* The campus also blocks ICMP to the Internet (the host itself cannot ping 1.1.1.1 or 8.8.8.8):
  lab diagnostics must use TCP, not ping.
* Not yet checked: the table after a host reboot (open question A17).

### Implementation (P1 step 4c)

Done by hand from the runbook [host-tailscale.md](../runbooks/host-tailscale.md), not by
Ansible: Tailscale on `insa` is the owner's only remote access path and belongs to the owner
(ADR-0027), the admin-console steps are manual anyway, and the host side is one idempotent
command. Plan reviewed by an independent agent before execution.

* `insa` advertises 10.10.0.0/24 and 10.20.0.0/24; SNAT stays on (Tailscale's default), so the
  lab router sees the source 10.255.255.1 and needs no route back to the tailnet. Tailscale
  keeps its iptables mode and adds no netfilter rule for this: its existing `ts-forward` mark
  and `ts-postrouting` masquerade apply, and the akasha chain `to_lab` (step 4b) accepts
  `tailscale0` → the two routes.
* The routes are approved by hand in the admin console (no `autoApprovers`).
* The tailnet policy replaces the default allow-all grant with two grants: the owner's devices
  reach each other (`autogroup:member` → `autogroup:self`), and only the laptop reaches the two
  lab routes. Policy tests (accept and deny) run on every save. The real policy holds Tailscale
  addresses and the owner's login and is kept outside the repository; the runbook has a
  template with placeholders.
* Only the laptop (Linux) runs `--accept-routes`; it is off by default on Linux. The policy
  does not hide routes from other devices, and Windows, Android and iOS accept them by default,
  so "Use Tailscale subnets" is to be turned off on any such device added later (none on
  2026-11-17); the policy denies them the lab either way.
* Tailnet clients all appear in the lab as 10.255.255.1 (SNAT): lab-side rules and logs cannot
  tell them apart. Accepted while the laptop is the only client.

### Confirmation (step 4c)

On 2026-11-17:

* Pre-check: no tagged device in the tailnet; IPv6 forwarding off on `insa`; tailscaled in
  iptables mode; the laptop's local network does not overlap the lab ranges.
* The new policy saved with its tests passing; SSH from the laptop to `insa` worked after
  every step.
* `ts-forward` and `ts-postrouting` identical before and after `--advertise-routes`.
* The packet filter `insa` receives from the control plane (`tailscale debug netmap`): the
  owner's three devices → `insa`, and only the laptop → 10.10.0.0/24, 10.20.0.0/24.
* The laptop has both routes in table 52 via `tailscale0`; its Internet traffic still leaves
  through its local gateway.
* Fake lab router (network namespace on `br-transit` with 10.10.0.1 and 10.20.0.1): HTTP from
  the laptop to both addresses works, with the client address 10.255.255.1; a connection from
  the lab to the laptop's Tailscale address is dropped by `from_lab` (counter 0 → 5).
* Independent review after execution: the policy, SNAT, table 52 and the return path are as
  intended. It found one gap: the host's routes to 10.10/24 and 10.20/24 exist only while
  `br-transit` is up; without them, tailnet packets to the lab follow the default route out of
  `eno1` into the campus network, masqueraded by Tailscale, and no akasha rule matches them.
  The owner chose (2026-11-17) to close it with a host firewall rule that drops lab-range
  destinations leaving through any interface other than `br-transit` (step 4d). Node key
  expiry of `insa` is open question C8.

### Implementation (P1 step 4d)

Role `host_firewall`, plan reviewed by an independent agent before execution:

* First rule of the `forward` chain: `ip daddr @lab_nets oifname != "br-transit" counter drop`.
  Routed packets to a lab range (10.10/24, 10.20/24, 10.255.255.0/29) may only leave through
  `br-transit`, whatever the routing table says. It matches the interface name, so it also
  holds when `br-transit` does not exist; a drop is final across base chains, so Tailscale's
  `ts-forward` accept cannot bypass it. Replies to the lab are de-masqueraded before the
  forward hook and leave through `br-transit`, so they are not affected.
* The role checks that every lab range has a main-table route via `br-transit` (the ranges and
  the routes live in two roles) and that the guard rule is loaded.
* Residual risk accepted by the owner: the host's own processes (output hook) are not matched,
  and nothing protects the lab ranges while the akasha table is not loaded (as in step 4b).

### Confirmation (step 4d)

On 2026-11-17:

* Pre-check: on `insa`, Tailscale accepts no routes and uses no exit node, table 52 holds no lab
  range, `ip rule` shows only the default and Tailscale's rules; the three lab routes go via
  `br-transit` (`linkdown`: no lab VM yet).
* Dry run with the host's `nft -c`: only the guard rule and comments change. Real run
  `failed=0`, second run `changed=0`.
* Control before the change (role not yet merged): a laptop connection to 10.10.0.200, routed
  by a test /32 route into a dummy interface, entered that interface: the leak path is real
  (the dummy interface discards packets; nothing went out of `eno1`).
* After the change, same test with IPv6 off on the dummy interface: the guard counter grew by
  5 (the SYN retries of a 5 s `curl`) and nothing was transmitted into the dummy interface.
* Regressions: laptop → fake lab router at 10.10.0.1 and 10.20.0.1 works (client 10.255.255.1),
  lab → laptop blocked; lab → Internet TCP 443 works and is masqueraded; the guard counter did
  not move during these tests. Host unchanged: no failed unit, NFS mounted, Tailscale,
  NetworkManager and the firewall unit active.
* To check later: the guard counter after normal use (it should only count tests).

### Consequences

* Good, because the campus network is protected by an explicit drop rule.
* Bad, because three firewalls (host nftables, libvirt, Tailscale) share the netfilter hooks
  and must be tested together.

## More Information

[research/04-host-and-network.md](../research/04-host-and-network.md)
