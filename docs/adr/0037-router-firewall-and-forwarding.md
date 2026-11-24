---
status: accepted
date: 2026-11-23
decision-makers: dhuy21
---

# Firewall and forwarding of the edge router

## Context and Problem Statement

[ADR-0028](0028-lab-edge-router-debian.md) fixed the router's firewall policy: default drop
in `input` and `forward`, the services the router offers, and which lab networks may reach
which. Before step 6b-3b turns on forwarding, four questions remained open:

* **Management → provider network.** ADR-0028 lists no path from `br-mgmt` to `br-ext`, yet
  from P3 the bastion (on `br-mgmt`) configures the K3s instances through their floating IPs
  on `br-ext` (SSH, Kubernetes API).
* **Lockout.** A wrong rule set can cut SSH to the router. The way back is then the serial
  console over SSH to `insa` (ADR-0035).
* **Boot.** If forwarding is on while the rule set failed to load, the router routes without
  a firewall.
* **Testing.** ADR-0028 asks for the policy to be tested from fake clients on each network
  before real VMs exist.

Facts checked on 2026-11-23:

* Debian 13's `nftables.service` (nftables 1.1.3-1) loads `/etc/nftables.conf` before
  `network-pre.target`, and its `ExecStop` is `nft flush ruleset`. VERIFIED:
  sources.debian.org `debian/nftables.service`.
* The router had no nftables and `ip_forward=0`.
* Neither netplan nor systemd-networkd sets forwarding on the router (VERIFIED on the router).
* `br_netfilter` is not loaded on `insa`, so traffic inside a lab bridge is not seen by the
  host's firewall (VERIFIED on `insa`).

## Decision Drivers

* No path from `br-ext` (instances, untrusted) into `br-mgmt` (OpenBao, Kolla) beyond what B4
  will allow.
* Fail closed: a broken or missing rule set must never mean an open router.
* A mistake must not need the console to recover from.
* ADR-0027: tests on `insa` touch only akasha's bridges, and only for the duration of the test.

## Considered Options

* **Management → provider network:**
  * open now, all ports, connections started from `br-mgmt` only;
  * keep it closed until P3, then open selected ports (22, 6443).
* **Loading:**
  * "commit confirmed": a timer restores the previous rules unless Ansible reaches the router
    again;
  * rely on the console.
* **Forwarding at boot:**
  * a unit that requires the firewall (fail-closed);
  * a plain `/etc/sysctl.d` file, set early at boot whatever the firewall's state.
* **Tests:**
  * fake clients in temporary network namespaces on `insa` now;
  * wait for real VMs (6c for `br-mgmt`, P2 for `br-ext`).

## Decision Outcome

Chosen by the owner on 2026-11-23: open **management → provider** now, **commit confirmed**,
**fail-closed forwarding**, and **fake clients now**. The Ansible role `router_firewall`
implements the following.

* **Rule set.** It is in `/etc/nftables.conf` (table `inet akasha`) and owns the whole rule
  set: the router is akasha's own VM.
  * `prerouting`:
    * IPv6 is dropped, because the lab has none;
    * a strict reverse-path check (`fib saddr . iif oif missing`) drops spoofed sources.
  * `input`: default drop. It accepts:
    * loopback, and established and related packets (this includes ICMP errors);
    * ping from the lab ranges and from 10.255.255.1;
    * DNS (TCP and UDP 53) and NTP (UDP 123), where each network may use only the router's
      address on that network;
    * SSH from `br-mgmt`, and SSH arriving on the WAN from 10.255.255.1 (the tailnet and
      `insa`, ADR-0008).

    Other packets are logged (5 lines per minute) and dropped.
  * `forward`: default drop. It accepts:
    * established and related packets;
    * `mgmt` → `wan` and `ext` → `wan`;
    * `wan` from 10.255.255.1 → `mgmt` and `ext`;
    * **`mgmt` → `ext`**.

    `ext` → `mgmt` stays closed until open question B4 is decided. Other packets are logged
    and dropped. There is no NAT.
* **Commit confirmed.** Ansible renders the rules into a candidate file,
  `/etc/akasha/nftables.conf`, checked with `nft -c`. The rules are pending when any of these
  holds:
  * the candidate differs from the confirmed `/etc/nftables.conf`;
  * the loaded rule set is not the one confirmed last. This is checked with a SHA-256 of
    `nft -s list ruleset` in `/etc/akasha/nftables.loaded.sha256`.

  For pending rules, the role:
  1. checks that its own SSH source is one the new rules accept (10.255.255.1 on the WAN, or
     the management network);
  2. saves the loaded rule set into `/run/akasha`;
  3. arms a transient timer (`systemd-run --on-active=180`, `AccuracySec=1s`). The timer
     restores the saved rules, and turns forwarding off if they contain no `inet akasha`
     table;
  4. loads the candidate in one transaction;
  5. closes its SSH connection (`meta: reset_connection`), and checks that the next task ran
     over a new connection by comparing `SSH_CLIENT`;
  6. stops the timer;
  7. only then copies the candidate to `/etc/nftables.conf` and records the fingerprint.

  If the router cannot be reached, the timer restores the previous rules after 180 s. The
  confirmed file is unchanged, so neither a reboot nor the next run loads the rejected rules
  without a timer.
* **Boot.** `nftables.service` is enabled and loads the confirmed file before any interface
  comes up.
* **Forwarding.** `akasha-forwarding.service` (`Requires=` and `After=nftables.service`) sets
  `net.ipv4.ip_forward=1` when it starts and sets it back to 0 when it stops.
  * If the firewall fails to load at boot, forwarding stays off. It comes back with a run of
    the role, or with `systemctl start akasha-forwarding` once nftables is loaded.
  * Stopping or restarting `nftables.service`, whose stop flushes the rules, stops forwarding
    with it, or stops and restarts it. The role never restarts nftables: it loads files with
    `nft -f`.
  * Package upgrades do restart it. Debian builds nftables with
    `dh_installsystemd --restart-after-upgrade`, and unattended upgrades are on (ADR-0035).
    During an upgrade, forwarding is therefore off for a moment. If the new `nft` rejects the
    file, forwarding stays off and `input` has no rules until the file is fixed.

### Consequences

* Good, because neither a failed boot nor a stopped firewall leaves the router routing
  without rules, and SSH to the router still works in that state: it uses `input`, not
  `forward`.
* Good, because a rule mistake rolls itself back, without the console. The file loaded at
  boot only ever holds rules that were confirmed, and a rule set that drifts from it is loaded
  again, commit confirmed, by the next run.
* Good, because the bastion can manage instances on floating IPs without a later change, and
  instances still cannot open connections into `br-mgmt`.
* Bad, because `mgmt` → `ext` opens every port: any compromised host on `br-mgmt` reaches
  every instance. Instances keep their own security groups.
* Bad, because every tailnet client appears as 10.255.255.1, like `insa` itself (ADR-0008), so
  the router cannot tell them apart.
* Bad, because the role is longer than a plain template: a candidate file, a fingerprint, a
  timer, a connection reset and a second unit.
* Bad, because `/etc/nftables.conf` is a modified conffile. An nftables upgrade that changes
  Debian's default file may wait for a manual `apt` (INFERRED from how unattended-upgrades
  treats conffile prompts).

### Confirmation

* Step 6b-3b, the role's checks:
  * `nftables` and `akasha-forwarding` active and enabled;
  * no rollback timer left;
  * `ip_forward=1`;
  * `inet akasha` is the only table, with policies accept, drop and drop for `prerouting`,
    `input` and `forward`;
  * the candidate equals the confirmed file, and the loaded rule set has the recorded
    fingerprint;
  * a second run reports `changed=0`.
* Fake clients on `br-mgmt` and `br-ext` (runbook `router.md`) give the expected result for
  every case:
  * Internet access;
  * DNS and NTP on the right address only;
  * SSH;
  * `mgmt` → `ext` open and `ext` → `mgmt` closed;
  * a spoofed source dropped;
  * the tailnet reaching both networks.
* Step 6b-4 (reboot): the rules load before the network, and forwarding comes on only after
  them.

### Implementation (2026-11-23)

Applied to the router from PR #66.

* **The dry run** installed nothing and failed nothing.
* **The first real run** went through the whole commit-confirmed sequence:
  * the SSH source checked (10.255.255.1 on `wan`);
  * the timer armed and the candidate loaded;
  * a new SSH connection proven;
  * the timer stopped, the boot file written and the fingerprint recorded;
  * then nftables and forwarding enabled.

  Every check passed.
* **A second run** reported `changed=0`.
* **On the router:**
  * `nftables` and `akasha-forwarding` are active;
  * `ip_forward=1`;
  * `inet akasha` is the only table;
  * no rollback timer is left.

The fake-client test on `insa` (runbook `router.md`) printed `ok` for all 14 cases:
* Internet access from both networks;
* DNS and NTP on the router's own address only;
* SSH from `mgmt` only;
* `mgmt` → `ext` open, and `ext` → `mgmt` closed.

The laptop reached both networks through the tailnet. Three spoofed SYNs from `br-ext` with
source 10.10.0.99 raised the `fib` counter from 0 to 6, counting retransmissions. The kernel
log showed an `akasha drop input` or `akasha drop forward` line for each blocked case. Every
test object was removed.

### Implementation (2026-11-24, step 6b-4)

* **Normal boot.** Times are from the same monotonic clock, in seconds since boot:
  * nftables ran from 5.88 s to 6.93 s;
  * `systemd-networkd` started at 9.80 s, and its first `Link UP` came at 9.96 s;
  * `akasha-forwarding` started at 12.62 s.

  So the rules were in place about 3 s before any interface was configured, and forwarding
  came on after them. Forwarding was 1 on `wan`, `mgmt` and `ext`, and the playbook then
  reported `changed=0`. `systemd-analyze critical-chain` counts from a different origin and
  is not evidence of this order.
* **Boot with a broken boot file.** A syntax error appended to `/etc/nftables.conf` was
  rejected by `nft -c` before the reboot. After the reboot:
  * `nftables.service` failed;
  * `akasha-forwarding.service` shows "Dependency failed", `ip_forward=0` and no rules;
  * SSH still worked.

  The role saw the boot file and the loaded rules drift, loaded the candidate commit
  confirmed, rewrote the boot file and started forwarding. A second run reported `changed=0`.
* **Rebuild from zero.** The role configured the new router with the same rule set (same
  fingerprint).

## More Information

* Before review, the rendered rule set was tested on 2026-11-23 in a Debian 13 container, with
  network namespaces standing in for `insa`, the router and both networks: 22 of 23 cases
  matched. The 23rd case was a wrong expectation of the test, not of the rules: SSH from
  `br-mgmt` is accepted on every router address.
* The role checks SSH with `printenv SSH_CLIENT` without `become`, because sudo resets the
  environment.
* An independent review of the plan and the code on 2026-11-23 found two blockers, both fixed
  before anything ran:
  * the first version wrote `/etc/nftables.conf` before confirmation, so a rolled-back rule
    set would have come back at boot or with the next run;
  * the fake-client test served the host's `/root` over HTTP.

  The review also asked for these changes, all made:
  * the timer's accuracy;
  * a check of Ansible's own SSH source before loading;
  * a fail-closed rollback;
  * the effect of package upgrades;
  * a robust and conclusive fake-client test.
* Verified in a Debian 13 container (nftables 1.1.3): reloading the same file or restoring the
  saved rule set gives the same fingerprint; a rollback to an empty rule set turns forwarding
  off.
* `meta: reset_connection` ignores `when:` (ansible-core 2.20, `plugins/strategy/__init__.py`),
  so the role resets the connection and proves a new one on every run.
