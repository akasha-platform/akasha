# Edge router: DNS, time, firewall and forwarding

Design:
* [ADR-0028](../adr/0028-lab-edge-router-debian.md): the router and its DNS;
* [ADR-0036](../adr/0036-router-time-over-ntp.md): time;
* [ADR-0037](../adr/0037-router-firewall-and-forwarding.md): firewall and forwarding.

Managed by the Ansible roles in `infra/ansible/playbooks/router.yml`:

| Role | Does | Tag |
|---|---|---|
| `router_dns` | Unbound | `dns` |
| `router_time` | chrony | `time` |
| `router_firewall` | nftables, `akasha-forwarding` | `firewall` |

Commands run on the router (`ssh debian@10.10.0.1`) unless stated otherwise.

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

## Firewall and forwarding

Ansible renders the rules into the candidate `/etc/akasha/nftables.conf`. The boot file
`/etc/nftables.conf` only ever receives a candidate that was confirmed. A run loads the
candidate "commit confirmed" when either of these holds:
* the candidate differs from the boot file;
* the loaded rule set is not the one confirmed last (fingerprint
  `/etc/akasha/nftables.loaded.sha256`).

The sequence is:
1. Ansible checks that its own SSH source is accepted by the new rules (10.255.255.1 on `wan`,
   or `mgmt`);
2. it saves the loaded rules to `/run/akasha/firewall-rollback.nft`;
3. it arms `akasha-firewall-rollback.timer` (180 s);
4. it loads the candidate;
5. it reconnects over a new SSH connection;
6. it stops the timer;
7. it copies the candidate to `/etc/nftables.conf` and records the fingerprint.

If the play stops between steps 4 and 6, wait 3 minutes. The timer restores the previous rules,
and turns forwarding off if they hold no `inet akasha` table. The boot file was not touched, so
fix the role and run it again.

```bash
sudo nft list ruleset                       # one table, inet akasha
systemctl is-active nftables akasha-forwarding   # active active
cat /proc/sys/net/ipv4/ip_forward           # 1
sudo cmp /etc/akasha/nftables.conf /etc/nftables.conf && echo confirmed
systemctl list-timers akasha-firewall-rollback.timer   # nothing, outside a run
sudo journalctl -k -g 'akasha drop' -n 20   # dropped packets (at most 5 lines per minute and chain)
sudo nft list ruleset | grep 'counter packets [1-9]'   # which drop rules matched
```

Forwarding depends on the firewall: `akasha-forwarding.service` requires `nftables.service`.
* Never `systemctl restart nftables`: its stop flushes the rules, and forwarding stops and
  restarts with it.
* An nftables package upgrade (unattended upgrades) restarts it the same way, so forwarding is
  off for a moment.
* After editing a file by hand, run the role: it loads the file commit confirmed.

## Firewall failed at boot

- **Symptom:** `systemctl is-active nftables` shows `failed`; `akasha-forwarding` shows
  `inactive` (its dependency failed); `ip_forward` is 0.
- **Impact:** the lab is not routed (fail-closed). `input` has no rules either, so SSH to the
  router works.
- **Diagnosis:** `journalctl -b -u nftables`, then `sudo nft -c -f /etc/nftables.conf`.
- **Mitigation:** run the role. It loads the rules commit confirmed and starts
  `akasha-forwarding`. Starting `nftables` by hand does not start `akasha-forwarding` again:
  `sudo systemctl start akasha-forwarding` afterwards.

## Locked out by the firewall

- **Symptom:** SSH to the router times out after the rollback window (more than 3 minutes).
- **Mitigation:** on the serial console (runbook `lab-vms.md`):

  ```bash
  sudo systemctl stop akasha-forwarding   # no routing without rules
  sudo nft flush ruleset                  # SSH reachable again
  ```

  Then fix the role and run it again. The run sees the loaded rules differ from the confirmed
  ones and loads its candidate commit confirmed.

## Test with fake clients (insa)

Two temporary network namespaces stand in for VMs on `br-mgmt` and `br-ext`. The test uses
only akasha's bridges and names starting with `akasha-t` (ADR-0027). `ip netns` leaves an
empty `/run/netns` mount on `insa` until the next reboot.

Before starting, check that `br_netfilter` is not loaded (`lsmod | grep br_netfilter` prints
nothing): otherwise traffic inside the bridges would cross the host's firewall.

1. **Laptop**, before the test: note the router's anti-spoofing counter.

   ```bash
   ssh debian@10.10.0.1 sudo nft list chain inet akasha prerouting | grep fib
   ```

2. **insa**, in an interactive SSH session:
   * The script stops twice, at the prompts **A** and **B**, for the laptop steps.
   * It removes everything it created when it ends, including on Ctrl-C or a lost session.
   * The cleanup function can be run again alone.
   * The web servers serve an empty temporary directory.

```bash
sudo bash -s <<'EOF'
set -u
for t in ip python3 dig curl timeout; do command -v "$t" >/dev/null || { echo "missing $t"; exit 1; }; done
cleanup() {
  for n in akasha-tm akasha-te; do
    ip netns pids "$n" 2>/dev/null | xargs -r kill
    ip link del "$n-h" 2>/dev/null; ip netns del "$n" 2>/dev/null
  done
  rm -rf /tmp/akasha-test-www
  echo "cleaned up"
}
cleanup; trap cleanup EXIT; trap 'exit 130' INT HUP TERM
mkdir -m 0755 /tmp/akasha-test-www
mk() {   # mk <netns> <bridge> <address/len> <gateway>; the peer is created inside the netns
  ip netns add "$1"; ip -n "$1" link set lo up
  ip link add "$1-h" type veth peer name "$1-n" netns "$1"
  ip link set "$1-h" master "$2" up
  ip -n "$1" addr add "$3" dev "$1-n"; ip -n "$1" link set "$1-n" up
  ip -n "$1" route add default via "$4"
  ip netns exec "$1" python3 -m http.server 8080 --bind "${3%/*}" --directory /tmp/akasha-test-www >/dev/null 2>&1 &
}
mk akasha-tm br-mgmt 10.10.0.250/24 10.10.0.1
mk akasha-te br-ext  10.20.0.250/24 10.20.0.1
sleep 2

tcp() {  # tcp <netns> <address> <port> <expected: open|closed>
  if ip netns exec "$1" timeout 3 bash -c "</dev/tcp/$2/$3" 2>/dev/null; then r=open; else r=closed; fi
  [ "$r" = "$4" ] && echo "ok     $1 -> $2:$3 $r" || echo "WRONG  $1 -> $2:$3 $r (expected $4)"
}
dns() {  # dns <netns> <server> <expected: answer|none>
  a=$(ip netns exec "$1" dig +short +time=2 +tries=1 @"$2" router.akasha.internal 2>/dev/null)
  [ "$a" = 10.10.0.1 ] && r=answer || r=none
  [ "$r" = "$3" ] && echo "ok     $1 dns @$2 $r" || echo "WRONG  $1 dns @$2 $r (expected $3)"
}
ntp() {  # ntp <netns> <server> <expected: answer|none>; the transmit timestamp is filled in
  r=$(ip netns exec "$1" python3 -c 'import socket,struct,sys,time
s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM); s.settimeout(3); t=time.time()
p=bytearray(48); p[0]=0x23; p[40:48]=struct.pack("!II",int(t)+2208988800,0)
try:
    s.sendto(bytes(p),(sys.argv[1],123)); s.recv(48); print("answer")
except OSError: print("none")' "$2")
  [ "$r" = "$3" ] && echo "ok     $1 ntp @$2 $r" || echo "WRONG  $1 ntp @$2 $r (expected $3)"
}

tcp akasha-tm 1.1.1.1 443 open;  tcp akasha-te 1.1.1.1 443 open    # Internet (NAT on insa)
dns akasha-tm 10.10.0.1 answer;  ntp akasha-tm 10.10.0.1 answer
dns akasha-te 10.20.0.1 answer;  ntp akasha-te 10.20.0.1 answer
dns akasha-te 10.10.0.1 none;    ntp akasha-te 10.10.0.1 none      # only the router's address on each network
dns akasha-tm 10.20.0.1 none
tcp akasha-tm 10.10.0.1 22 open                                    # SSH from mgmt
tcp akasha-te 10.20.0.1 22 closed; tcp akasha-te 10.10.0.1 22 closed   # never from ext
tcp akasha-tm 10.20.0.250 8080 open                                # mgmt -> ext
tcp akasha-te 10.10.0.250 8080 closed                              # ext -> mgmt closed (B4)
read -r -p "A: laptop: curl -m3 http://10.10.0.250:8080/ and http://10.20.0.250:8080/ (both list an empty directory), then Enter " _ </dev/tty
ip -n akasha-te addr add 10.10.0.99/32 dev akasha-te-n             # spoofed source from ext
for i in 1 2 3; do ip netns exec akasha-te curl -s -m2 --interface 10.10.0.99 -o /dev/null https://1.1.1.1; done
echo "spoofed packets sent"
read -r -p "B: laptop: read the fib counter again (step 3), then Enter to clean up " _ </dev/tty
EOF
```

3. **Laptop**, at prompt B: the `fib` counter has grown by at least 3 since step 1, because
   the spoofed SYNs were dropped. Then press Enter on `insa`.

```bash
ssh debian@10.10.0.1 sudo nft list chain inet akasha prerouting | grep fib
ssh debian@10.10.0.1 sudo journalctl -k -g 'akasha drop' -n 20   # the blocked cases above
```

Every line printed by the script must start with `ok`. A `WRONG` line is a finding: keep the
output, do not change the rules by hand.

## Roll back

```bash
# on the router: back to the cloud image's state (forwarding off first)
sudo systemctl disable --now akasha-forwarding nftables   # stopping nftables flushes the rules
sudo rm /etc/systemd/system/akasha-forwarding.service && sudo systemctl daemon-reload
sudo apt purge nftables unbound bind9-dnsutils chrony
sudo apt install systemd-timesyncd
```

Or rebuild the router from code (runbook `lab-vms.md`, "Locked out of SSH") and run the
playbook again.
