---
status: accepted
date: 2026-11-17
decision-makers: dhuy21
---

# Lab time source: the edge router keeps UTC over HTTPS and serves NTP to the lab

## Context and Problem Statement

The lab's clocks must agree with each other and stay close to real UTC: TLS validity,
Keystone and OpenBao tokens, Galera/RabbitMQ/etcd, log correlation, and AWS S3 (SigV4 rejects
requests skewed by more than 15 minutes). The tightest external limit is OpenBao's JWT login
used by CI and in-cluster clients (GitHub Actions OIDC, ADR-0011): `clock_skew_leeway` defaults to 60 s. VERIFIED:
openbao `website/content/docs/api/auth/jwt.mdx`. Kolla-Ansible 2026.1 no longer deploys
chrony, and its prechecks require an active time daemon reporting `synchronized: yes`.
VERIFIED: kolla-ansible `stable/2026.1` `ansible/roles/prechecks/tasks/timesync_checks.yml`.

Measured on `insa` (2026-11-16 and 2026-11-17):

* From the campus, NTP (UDP 123) to public servers is blocked; DNS and HTTPS work.
* The host runs `systemd-timesyncd` towards the Debian pool and has never synchronised since
  it booted on 2026-11-13 (0 packets); the campus DHCP offers no NTP server.
* The host clock was 18.0 s behind UTC on 2026-11-17 09:48 UTC (±0.25 s, against an
  NTP-synced laptop; an HTTPS `Date` header agrees). Its drift rate is not known yet.
* The host's clocksource is `tsc` with `constant_tsc` and `nonstop_tsc`, so `ptp_kvm` works
  in its guests.

The host's time service belongs to the school (ADR-0027): akasha does not change it. How
does the lab get correct time?

## Decision Drivers

* Lab within well under 60 s of UTC, VMs consistent with each other.
* No change to the host (ADR-0027); no listening service on the uplink.
* Works for the L1 VMs and for OpenStack instances (K3s nodes, nested L2).
* Built from code with the router (ADR-0028); failures visible, not silent.

## Considered Options

* **A. The router keeps UTC over HTTPS and serves NTP to the lab.**
* **B. Every VM follows the host clock through `ptp_kvm`** (`refclock PHC /dev/ptp_kvm`): no
  network needed, nanosecond agreement with the host, but the lab inherits the host's error
  (−18 s and drifting), which will exceed OpenBao's 60 s leeway. `ptp_kvm` in nested L2
  guests also needs a newer L1 kernel or an invariant TSC exposed to the computes (INFERRED).
* **C. A campus NTP server** reached through an exception in the host firewall: DHCP offers
  none; needs the school's IT and a rule towards a campus host. Possible later improvement.
* **D. An NTP server over the tailnet**: no always-on off-site device exists.
* **E. kvm-clock only**: wall time set at boot, then the host's rate; fails Kolla's prechecks.

## Decision Outcome

Chosen option: **"A"**, chosen by the owner on 2026-11-17.

* On the router, **htpdate is the only program that sets the clock**: Debian's htpdate 1.3.7
  in daemon mode, first poll steps the clock, then smooth adjustment and drift compensation
  (`-D -s -x`), **certificate verification on (`-c`)** and 3–4 independent `https://` servers.
  Debian's default configuration uses plain HTTP and no verification (`HTP_SERVERS="www.ntp.org
  www.example.com"`, `-c` is "default no verification"), so it is always overridden. VERIFIED:
  sources.debian.org htpdate 1.3.7-2 (`debian/default`, `htpdate.8`). Accuracy "usually within
  0.5 seconds", enough for every limit above.
* **chronyd runs with `-x`** ("disables the control of the system clock … to operate as an
  NTP server", VERIFIED: https://chrony-project.org/doc/4.6/chronyd.html), `local stratum 10`,
  and `allow` for 10.10.0.0/24 and 10.20.0.0/24. It starts only after htpdate's first
  successful step, so that the lab never learns the host-derived time first.
* **L1 VMs** (bastion, core, controller, computes): chrony with the router's `br-mgmt` address
  as source (`iburst`), plus `refclock PHC /dev/ptp_kvm noselect`: not used for the clock, but
  it shows the host's offset from UTC at no cost and with no host change. They report
  `synchronized: yes`, which passes Kolla's prechecks.
* **OpenStack instances**: the router's `br-ext` address is given as NTP server through
  Neutron OVN DHCP (`ovn_dhcp4_global_options = ntp_server:<address>`, VERIFIED: neutron
  `ovn_conf.py`), with cloud-init `ntp:` as fallback for images that ignore DHCP option 42.
* **Host**: unchanged.

### Consequences

* Good, because the lab follows UTC within about a second without touching the host or
  opening anything on the uplink.
* Good, because one source of truth (the router) keeps the VMs consistent with each other.
* Bad, because time depends on the TLS-authenticated `Date` headers of a few public web sites
  (trust and availability outside akasha's control); mitigated by 3–4 independent operators.
* Bad, because chrony's `local` mode keeps serving a confident stratum-11 time when every
  HTTPS source is gone, so the failure is silent: htpdate's log and the router's offset must
  be monitored (host monitoring, roadmap P1 step 5 and P5).
* Bad, because the router's own `timedatectl` will not report synchronised (chronyd does not
  control its clock); checks on the router use htpdate's log instead.

### Confirmation

Open question A18, after the router exists: first-boot ordering (htpdate steps before chronyd
serves), offset of the router and of an L1 VM against UTC, the `ptp_kvm` reading of the host
offset, behaviour when the HTTPS sources are unreachable, and an OpenStack instance receiving
the NTP server by DHCP.

## More Information

* Open question A20: the drift rate of the host clock (second measurement). The earlier
  "≈ 50 ppm" estimate assumed the clock was right at boot, which the ~3 s gap between the RTC
  and the system clock contradicts.
* `docs/research/04-host-and-network.md` proposed "host chrony → OPNsense → chrony in every
  VM"; that chain would have changed the school's time service and is replaced by this ADR.

## Updates

* 2026-11-23: NTP from the campus works again since about 2026-11-18 (measurements of
  2026-11-22 in [ADR-0036](0036-router-time-over-ntp.md)). The router part of this decision
  (htpdate, chronyd `-x`, `local stratum 10`) is replaced by ADR-0036: chrony on the router
  follows UTC over NTP and serves it to the lab, without `local`. The parts for the L1 VMs and
  the OpenStack instances stay as decided here.
* 2026-11-24 (step 6c-1, after the independent review): the L1 VMs do **not** carry
  `refclock PHC /dev/ptp_kvm noselect` in their chrony configuration. chronyd stops at boot
  when a refclock device cannot be opened (VERIFIED: chrony 4.6.1 `refclock_phc.c` "Could
  not open PHC", fatal; Debian's `chrony.service` has no `Restart=`). ptp_kvm needs a stable
  TSC on the host, so a diagnostic would make every VM's time service depend on it.
  * The role `lab_client` loads ptp_kvm and reads the host's offset once per run instead,
    with a separate `chronyd -Q 'refclock PHC /dev/ptp_kvm'` that prints the offset and
    exits.
  * The time chain itself is unchanged: chrony with the router as its only source, and the
    Debian pool line of the packaged `chrony.conf` turned off. That file is a modified
    conffile, so a chrony update that changes it may wait for a manual `apt` (INFERRED).
