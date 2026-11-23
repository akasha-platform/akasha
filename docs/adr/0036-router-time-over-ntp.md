---
status: accepted
date: 2026-11-23
decision-makers: dhuy21
---

# The edge router follows UTC over NTP with chrony and serves it to the lab

## Context and Problem Statement

[ADR-0029](0029-lab-time-source.md) made the router take UTC from HTTPS `Date` headers with
htpdate, because from the campus NTP (UDP 123) was blocked. chronyd then served that time to
the lab without controlling the clock (`-x`, `local stratum 10`). Before step 6b-3 the
router's egress was measured again, on 2026-11-22. The tests ran from `insa` and from the
router, and both gave the same results, so the restrictions come from the campus, not from the
lab's path. The probes were read-only, sent from Python's standard library:

* **NTP works again.**
  * A request with its transmit timestamp filled in, as every real client sends, gets an
    answer from the Debian pool, PTB and Cloudflare.
  * A request whose transmit timestamp is empty never gets an answer. Some filter on the
    campus path drops these requests (INFERRED from the difference).
  * `insa`'s systemd-timesyncd had sent 0 packets between 2026-11-13 and 2026-11-17. On
    2026-11-22 it had sent 150 and was 0.9 ms off.
  * The router's timesyncd was synchronised to a Debian pool server: 24 packets, frequency
    +16.658 ppm, which is about 1.4 s/day of drift without correction.
  * NTP has therefore been open since about 2026-11-18. The campus gave no notice of the
    change either way.
* **NTS key exchange is blocked.** TCP 4460 to time.cloudflare.com, nts.netnod.se and
  ptbtime1.ptb.de timed out.
* **DNS over TLS is blocked.** TCP 853 to 1.1.1.1 and 9.9.9.9 timed out.
* **Plain DNS is not intercepted.** Port 53, UDP and TCP, gives real answers from the server
  asked (`id.server` names the resolver instance, and a root server answers with `aa`), with
  DNSSEC signatures.
* **HTTPS works.** TCP 443 is open, and the `Date` header was −0.3 to −0.4 s off.

With NTP available, should the router keep the HTTPS chain of ADR-0029?

## Decision Drivers

* Lab within well under 60 s of UTC (OpenBao JWT leeway, ADR-0029), VMs consistent with each
  other, Kolla's prechecks passed (`synchronized: yes`).
* Failures visible, not silent (ADR-0029's drivers).
* The fewest moving parts on a router that is a single point of failure (ADR-0028).
* No change to the host (ADR-0027).

## Considered Options

* **A. Keep ADR-0029**:
  * htpdate sets the clock from 3–4 HTTPS servers, about 0.5 s accuracy;
  * chronyd `-x` with `local stratum 10` serves that time to the lab;
  * the router never reports itself synchronised.
* **B. chrony as NTP client and server, without `local`.** One daemon, millisecond accuracy,
  and the router reports synchronised.
* **C. chrony with NTS** (authenticated NTP). TCP 4460 is blocked, so this is not possible
  today.
* **D. B with htpdate as a fallback.** Two programs could each set the clock and would need
  arbitration. This becomes the answer if NTP is blocked again (see Consequences).

## Decision Outcome

Chosen option: **"B"**, chosen by the owner on 2026-11-22. This replaces the router part of
ADR-0029 (htpdate, chronyd `-x`, `local stratum 10`).

On the router, the Ansible role `router_time` does the following:

* **chrony replaces systemd-timesyncd.** Both packages provide and conflict on `time-daemon`,
  so installing chrony removes timesyncd. VERIFIED: chrony 4.6.1-3+deb13u2 and systemd
  257.13-1~deb13u1 `debian/control`, and in a Debian 13 container on 2026-11-23.
* **Debian's `chrony.conf` is kept**, including:
  * the pool `2.debian.pool.ntp.org`;
  * `makestep 1 3`: the clock is stepped only in the first three updates, then slewed;
  * `rtcsync`;
  * `leapseclist`.
* **The role adds two files:**
  * `/etc/chrony/sources.d/akasha.sources` with `ptbtime1.ptb.de` and `ptbtime2.ptb.de`. These
    are run by the PTB, Germany's national metrology institute; they are stratum 1 and
    operated independently of the pool.
  * `/etc/chrony/conf.d/akasha.conf` with `allow` for 10.10.0.0/24 and 10.20.0.0/24. chrony
    serves no client unless `allow` names it (VERIFIED: `chrony.conf(5)`, `allow`).
* **No leap-smearing server.** Debian's `chrony.conf` states that `leapseclist` "must be
  commented out when using time sources serving leap-smeared time" (VERIFIED: chrony
  4.6.1-3+deb13u2 `debian/chrony.conf`). This rules out time.google.com, which smears.
* **No `local` directive.** When every source is lost, the router keeps serving, but its root
  distance grows; it does not present itself as a confident stratum-10 server.
* **L1 VMs and OpenStack instances: unchanged from ADR-0029.**
  * L1 VMs run chrony with the router as source, plus `refclock PHC /dev/ptp_kvm noselect`.
  * OpenStack instances get the router's `br-ext` address through OVN DHCP, with cloud-init
    `ntp:` as fallback.

The DNS choice was made at the same time and with the same measurements, and is recorded in
[ADR-0028](0028-lab-edge-router-debian.md) Updates: Unbound forwards to Google and Cloudflare
over port 53 and validates DNSSEC itself.

### Consequences

* Good, because the router follows UTC within milliseconds instead of about half a second,
  with one standard daemon instead of two programs.
* Good, because the router's `timedatectl` reports synchronised. This removes ADR-0029's
  "the router will not report synchronised" consequence.
* Good, because a lost upstream shows up in the router's `chronyc tracking` (growing root
  dispersion), and later in its clients, instead of a silent stratum-11 time.
* Bad, because NTP is not authenticated. An attacker on the campus path could shift the
  router's time. It is mitigated by sources from several operators (the pool's servers and the
  PTB): chrony's source selection rejects sources that disagree with the majority.
* Bad, because the router depends on the campus keeping UDP 123 open, and the campus blocked
  it for at least five days in November 2026. Without sources, the router keeps its last
  frequency and free-runs.
  * Its clients keep accepting it until its root distance exceeds their `maxdistance` (3 s by
    default). Root dispersion grows by about 1 ppm (`maxclockerror`), so this takes about a
    month (INFERRED).
  * Before P5's monitoring, the router's `chronyc tracking` is checked by hand (runbook
    `router.md`).
  * If NTP is blocked again, the response is a new decision: option D, or option C of
    ADR-0029 (a campus NTP server).

### Confirmation

* Step 6b-3a, on the router, the role's checks:
  * chrony active and enabled, timesyncd not installed;
  * `chronyc waitsync` returns, with less than 0.1 s of remaining correction;
  * `timedatectl` shows `NTPSynchronized=yes`, and the leap status is `Normal`;
  * exactly one selected source;
  * `chronyc accheck` allows 10.10.0.10 and 10.20.0.100, and denies 10.255.255.1;
  * a second run reports `changed=0`.
* Open question A18 for the rest of the chain: an L1 VM against the router, the `ptp_kvm`
  reading, behaviour without sources, and OVN DHCP.

### Implementation (2026-11-23)

Applied to the router from PR #65, together with the DNS role. Two defects of the first
version, found on the router, were fixed in the same pull request:

* the expected lists of the checks were built with `\1` in a Jinja string, which Jinja reads as
  the character U+0001;
* `validate:` failed closed because of chronyd's AppArmor profile (see below).

The last real run reported `failed=0` with every check passed, and a second run reported
`changed=0`.

Confirmed on 2026-11-23 (`chronyc -n tracking` and `sources` on the router):

* the router is 0.8 ms from NTP time, with leap status `Normal`;
* six sources, all with reach 377: four from the Debian pool, and both PTB servers at
  stratum 1. NTP to the PTB therefore passes the campus;
* the frequency is 16.323 ppm slow, consistent with timesyncd's +16.658 ppm of 2026-11-22;
* systemd-timesyncd is removed;
* `chronyc accheck` allows both lab ranges and denies 10.255.255.1.

Unbound and chrony together raised the router's used memory from 97 to 111 MiB (`free -m`).

## More Information

* The probes (read-only Python, no extra package) were run on 2026-11-22 from `insa` and from
  the router.
* `chrony.conf(5)` 4.6: `allow`, `sourcedir`, `confdir`, `leapsecmode` (leap smear). `chronyd -p`
  parses the configuration and exits, so the role uses it to check files before writing them.
* Debian confines `/usr/sbin/chronyd` with an AppArmor profile (chrony 4.6.1-3+deb13u2
  `debian/usr.sbin.chronyd`) that lets it read `/etc/chrony` and `/run/chrony` but not
  Ansible's temporary files, even as root. The role therefore checks a copy in `/run/chrony`
  (found on the router on 2026-11-23: the first check failed closed with "Permission
  denied").
* Leap smear: https://developers.google.com/time/smear (Google's public NTP smears leap
  seconds).
