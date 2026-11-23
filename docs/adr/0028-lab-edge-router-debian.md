---
status: accepted
date: 2026-11-17
decision-makers: dhuy21
---

# Lab edge router: a minimal Debian 13 VM instead of OPNsense

## Context and Problem Statement

ADR-0008 made OPNsense (3 GB, its official minimum) the edge of the lab: gateway of
`br-mgmt` and `br-ext`, firewall between the lab networks, Unbound for `akasha.internal` and
NTP for the lab. On 2026-11-16 the owner set a new constraint: at least 3 GB of the host's
31 GiB must stay free, while the design committed about 100% of it. The owner chose to
replace OPNsense with a lighter router (open question B10). Which router?

What the router must do (ADR-0008, unchanged):

* WAN on `br-transit`: 10.255.255.2/29, default route via the host 10.255.255.1. The host is
  the only NAT to the uplink; the router routes **without NAT**.
* Gateway .1 of `br-mgmt` (10.10.0.0/24) and of `br-ext` (10.20.0.0/24, provider and
  floating-IP network).
* Stateful firewall between these networks; operator traffic arrives from the tailnet already
  masqueraded to 10.255.255.1 (step 4c).
* DNS for the lab: local zone `akasha.internal` plus recursion to public resolvers.
* Time server for the lab ([ADR-0029](0029-lab-time-source.md)).

## Decision Drivers

* Lowest RAM (owner's first priority).
* Everything as code and rebuildable from Git: OpenTofu, cloud-init, Ansible, no click-ops
  (owner's second priority).
* One toolchain: same image pipeline, version pinning and Ansible conventions (ADR-0022,
  ADR-0026) as the other VMs.
* Security support for the lab's life (one semester, possibly longer).
* ADR-0027: nothing of this runs on the school's host.

## Considered Options

Research and independent review on 2026-11-17 (sources in the notes below):

* **OPNsense** (status quo): official minimum 3 GB RAM. VERIFIED:
  https://docs.opnsense.org/manual/hardware.html. Breaks the 3 GB-free constraint.
* **Debian 13 genericcloud VM**: official minimum without desktop 512 MB RAM. VERIFIED:
  https://www.debian.org/releases/trixie/amd64/ch03s04.en.html. Same image as the other VMs
  (dated directory + SHA512SUMS, https://cloud.debian.org/images/cloud/), full cloud-init,
  Ansible built-in modules. Security support to 2028-08-09, LTS to 2030-06-30. VERIFIED:
  https://wiki.debian.org/LTS. Unbound 1.26.2 (trixie-security) and chrony 4.6.1 in trixie.
* **Alpine 3.24 VM**: 128 MB minimum (wiki), official cloud-init qcow2, support to 2028-06-01
  (VERIFIED: https://alpinelinux.org/releases/). About 256 MB less than Debian, but a second
  OS family (musl, OpenRC, apk) in every Ansible role; free page reporting (ADR-0016) already
  returns a guest's unused memory, so the real saving is smaller (INFERRED).
* **VyOS**: current documentation states a minimum of 4 GB RAM and 10 GB storage (VERIFIED:
  https://docs.vyos.io/en/1.5/installation/install.html); free Stream images are ISO only,
  without a security-patch commitment; LTS needs a subscription. Fails the RAM driver.
* **OpenWrt 25.12**: lightest (about 128 MB, INFERRED), but no cloud-init, its own UCI
  configuration model, and support until about 2027-03 (INFERRED; the official page could not
  be fetched).
* **Router role merged into the bastion**: no extra VM, but the gateway of the floating-IP
  network would sit next to the OpenTofu/Kolla credentials and the CI SSH entry point, and the
  two roles would fail together.
* **Router role on the host**: needs host addresses and lab-facing services on `br-mgmt` and
  `br-ext`; contradicts ADR-0008 (unaddressed bridges) and ADR-0027. Rejected.

## Decision Outcome

Chosen option: **"Debian 13 genericcloud VM"**, chosen by the owner on 2026-11-17.

* VM `router`: 1 vCPU (E-core), **512 MB RAM**, 8 GB thin disk, three NICs: `br-transit`
  10.255.255.2/29, `br-mgmt` 10.10.0.1/24, `br-ext` 10.20.0.1/24. Created by OpenTofu like the
  other VMs; network and SSH keys by cloud-init (network-config v2 matched by MAC address);
  everything else by an Ansible role.
* Routing: `net.ipv4.ip_forward=1`, default route via 10.255.255.1, no masquerade.
* Firewall (nftables), default drop in `input` and `forward`:
  * `input`: DNS and NTP from the lab ranges on the `br-mgmt` and `br-ext` addresses; SSH from
    `br-mgmt` and from the tailnet (source 10.255.255.1), so the owner can still reach the
    router when the bastion is down; nothing else.
  * `forward`: established/related; `br-mgmt` → Internet; `br-ext` → Internet; the tailnet
    (source 10.255.255.1) → `br-mgmt` and `br-ext`; `br-ext` → `br-mgmt` **only** to the
    external API VIP and API ports (open question B4 decides one or two VIPs). Kolla's
    internal services (Galera, RabbitMQ, OpenBao on `core`) are never reachable from
    `br-ext`: Kolla requires that `api_interface` is not reachable from outside.
* DNS: Unbound, local zone `akasha.internal`, recursion to public resolvers (UDP/TCP 53 work
  from the campus, step 4b), answering only the lab ranges.
* Time: the router is the lab's time server ([ADR-0029](0029-lab-time-source.md)).
* Single point of failure, accepted: when the router is down, the lab loses its default
  route, DNS, time and all tailnet access to the lab (the host routes 10.10/24 and 10.20/24
  via 10.255.255.2); the way in is then `virsh console` over SSH to the host. Therefore:
  * the router keeps no state that is not in Git, and is rebuilt with `tofu apply` + Ansible;
  * it starts first (router → core → bastion → controller → computes), and only after the
    host firewall check of ADR-0008 (it does not autostart before that check exists);
  * clients use its IP addresses, not names, for DNS and NTP.

This replaces the OPNsense parts of ADR-0008 (sizing, Unbound and NTP on OPNsense) and of
`docs/research/04-host-and-network.md` ("OPNsense as a KVM guest"; its "host chrony →
OPNsense" chain is also replaced, by ADR-0029).

### Consequences

* Good, because about 2.5 GB of RAM is freed compared with OPNsense (3 GB → 0.5 GB), which
  makes the 3 GB-free constraint reachable; the RAM budget itself is revised separately.
* Good, because the router is built like every other VM (one image pipeline, one set of
  Ansible conventions, security updates through Debian).
* Good, because the firewall policy between the lab networks is code in Git, reviewed like
  any other change.
* Bad, because there is no web UI: diagnostics are `nft`, `unbound-control` and `chronyc` over
  SSH.
* Bad, because the router is a single point of failure for the lab and for remote access to
  it (mitigated by rebuild-from-code and the console path above).

### Confirmation

* Before building: check offline how the trixie genericcloud image renders network config
  (netplan + systemd-networkd or another renderer), e.g. `guestfish --ro -i -a <image>`.
* After deployment: idle RSS of the router measured (the 150–200 MB figure is ESTIMATED); the
  firewall policy tested from fake clients on each network (as for the host firewall); a
  rebuild from zero tested.

## More Information

* Open question A19, answered on 2026-11-18: the campus lets TCP 80 out. From a test
  namespace on `br-transit` (NAT through the host), `http://deb.debian.org`,
  `http://security.debian.org` and `http://cloud.debian.org/images/cloud/` all answered 200,
  like the HTTPS control; lab VMs can use the Debian mirrors as they are.
* Research and independent review notes of 2026-11-17 are summarised above; the full
  comparison included idle-RAM estimates (ESTIMATED) that the confirmation replaces with
  measurements.

## Updates

* 2026-11-22: the console path above needs a password, since the cloud image locks them all.
  The role `vm_base` gives `debian` a console-only password (SSH stays key-only, root refused),
  [ADR-0035](0035-access-to-the-lab-vms.md).
* 2026-11-23: the router's DNS and time, chosen by the owner on 2026-11-22 after the egress
  measurements recorded in [ADR-0036](0036-router-time-over-ntp.md):
  * Unbound **forwards** every name outside its local zones to Google (8.8.8.8, 8.8.4.4) and
    Cloudflare (1.1.1.1, 1.0.0.1) over plain port 53 and validates DNSSEC itself (Debian's
    default trust anchor). The campus does not intercept port 53 and blocks DNS over TLS.
    Unbound listens on 127.0.0.1, 10.10.0.1 and 10.20.0.1, never on the WAN address, and
    answers 10.10.0.0/24 and 10.20.0.0/24 only. The zone `akasha.internal` names every planned
    VM, with reverse records; VIP names wait for open question B4. Role `router_dns`.
  * The router itself keeps the resolvers cloud-init gave it (1.1.1.1, 9.9.9.9), so a broken
    Unbound does not stop its own updates.
  * Time: chrony over NTP, [ADR-0036](0036-router-time-over-ntp.md), role `router_time`.
