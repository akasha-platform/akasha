# Edge router: DNS and time for the lab

Design: [ADR-0028](../adr/0028-lab-edge-router-debian.md) (router, DNS) and
[ADR-0036](../adr/0036-router-time-over-ntp.md) (time). Managed by the Ansible roles
`router_dns` (Unbound) and `router_time` (chrony) in `infra/ansible/playbooks/router.yml`
(tags `dns` and `time`). Commands run on the router (`ssh debian@10.10.0.1`) unless stated
otherwise.

## Run the roles

```bash
cd infra/ansible
uv run ansible-playbook playbooks/router.yml --check --diff -e @~/akasha-private/lab_vms.yml
uv run ansible-playbook playbooks/router.yml -e @~/akasha-private/lab_vms.yml
# only DNS or only time (the private file is still needed by the first check):
uv run ansible-playbook playbooks/router.yml --tags dns -e @~/akasha-private/lab_vms.yml
```

The first dry run on a router without Unbound or chrony cannot check their files: the packages,
their checkers and their directories are not there yet. The real run checks each file with
`unbound-checkconf` or `chronyd -p` before writing it; a file that fails the check is not
written and the service keeps its previous configuration.

Each run ends with checks (sockets, answers, DNSSEC, synchronisation, NTP access). They wait
at most 3 minutes for chrony to synchronise after a restart.

## Check DNS

```bash
dig +short @10.10.0.1 os-ctl01.akasha.internal     # 10.10.0.11
dig +short @10.10.0.1 -x 10.10.0.11                # os-ctl01.akasha.internal.
dig @10.20.0.1 debian.org SOA +dnssec | grep flags # "ad": validated by Unbound itself
sudo ss -lnup | grep ':53 '                        # 127.0.0.1, 10.10.0.1, 10.20.0.1 (unbound)
                                                   # and 127.0.0.53/54 (systemd-resolved), never 10.255.255.2
sudo unbound-control status
```

The router itself still resolves through 1.1.1.1 and 9.9.9.9 (cloud-init, `resolvectl status
wan`), not through its own Unbound: `apt` on the router keeps working when Unbound is broken.

## DNS does not answer

- **Symptom:** a lab VM gets timeouts or `SERVFAIL` from 10.10.0.1 or 10.20.0.1.
- **Diagnosis:**
  - `systemctl status unbound` and `journalctl -u unbound -n 50`, then `sudo unbound-checkconf`.
  - `REFUSED`: the client is not in `router_dns_clients`.
  - `SERVFAIL` only for signed names: DNSSEC failure. Check the clock first (`chronyc tracking`;
    signatures have validity dates), then `sudo unbound-control forward` and an upstream directly:
    `dig @1.1.1.1 debian.org +dnssec`.
- **Mitigation:** `sudo systemctl restart unbound`. A wrong `akasha.conf`: fix the role and run
  it again (a broken file is never written by the role).
- **Escalation:** roll back (below) or rebuild the router (runbook `lab-vms.md`, "Locked out of
  SSH").

## Add or change a name

Edit `router_dns_hosts` in `infra/ansible/roles/router_dns/defaults/main.yml` (pull request),
then run the role with `--tags dns`. Each name gets its reverse record; an address outside
`router_dns_reverse_zones` needs its reverse zone added there too.

## Check time

```bash
chronyc -n tracking     # Leap status: Normal; System time within a few ms; Root dispersion small
chronyc -n sources      # one source marked ^*, the others ^+ or ^-
timedatectl show --property=NTPSynchronized   # NTPSynchronized=yes
sudo chronyc accheck 10.10.0.10               # 208 Access allowed
sudo chronyc accheck 10.255.255.1             # 209 Access denied
```

## The router lost its time sources

- **Symptom:** `chronyc -n sources` shows no `^*` and `Reach` 0 everywhere; `chronyc tracking`
  shows `Leap status: Not synchronised` or a root dispersion that keeps growing.
- **Impact:** none at first: the router free-runs with its last frequency. Its clients drop it
  once its root distance passes 3 s (about a month, INFERRED); then Kolla's prechecks, TLS and
  OpenBao logins start failing as clocks drift apart.
- **Diagnosis:**
  - DNS first: `getent hosts ptbtime1.ptb.de`.
  - Then NTP itself from `insa` and from the router. The campus blocked UDP 123 from
    2026-11-13 to about 2026-11-18 (ADR-0029, ADR-0036); test with a client that fills its
    transmit timestamp (chrony, timesyncd), since the campus drops requests without one:
    `chronyd -Q -t 10 'server ptbtime1.ptb.de iburst'` prints the offset without touching the
    clock.
- **Mitigation:** none inside akasha while UDP 123 is blocked. Record the dates in
  `docs/open-questions.md` and raise the decision with the owner: htpdate as a fallback
  (ADR-0036 option D) or a campus NTP server (ADR-0029 option C).

## Roll back

```bash
# on the router: back to the cloud image's state
sudo apt purge unbound bind9-dnsutils chrony
sudo apt install systemd-timesyncd
```

Or rebuild the router from code (runbook `lab-vms.md`, "Locked out of SSH") and run the
playbook again.
