# Host firewall (lab traffic on `insa`)

Design: [ADR-0008](../adr/0008-host-networking-and-access.md) (step 4b) and
[ADR-0027](../adr/0027-guest-on-the-school-host.md). Managed by the Ansible role
`host_firewall` (`infra/ansible/playbooks/host.yml`, tag `firewall`). Only packets entering or
leaving `br-transit`, `br-mgmt`, `br-tun` and `br-ext` are matched; the host's own traffic is
not. Commands run on `insa` as root.

## Run the role

The campus's public prefixes are not in the repository. Keep them in a private file and pass
it on every run (an empty list is the default):

```bash
# ~/akasha-private/host_firewall.yml (laptop, never committed)
# host_firewall_campus_nets: [<prefix>/<len>, ...]
cd infra/ansible
uv run ansible-playbook playbooks/host.yml -K --check --diff --tags network,firewall -e @~/akasha-private/host_firewall.yml
uv run ansible-playbook playbooks/host.yml -K --tags network,firewall -e @~/akasha-private/host_firewall.yml
```

## Check after every reboot (before starting the lab router)

```bash
systemctl is-active akasha-firewall          # active
nft list table inet akasha | head -3         # table inet akasha {
cat /proc/sys/net/ipv4/conf/br-{transit,mgmt,tun,ext}/forwarding   # 1 0 0 0
```

If the table is missing, `br-transit` routes the lab **without filter and without NAT**: do not
start lab VMs; run `systemctl restart akasha-firewall` and read `journalctl -u akasha-firewall`.

## Things that remove or weaken the rules

- `nft flush ruleset`, or enabling Debian's `nftables.service`: its default `/etc/nftables.conf`
  starts with `flush ruleset` and also removes Tailscale's and libvirt's rules. Never enable it.
- Changing `net.ipv4.ip_forward` from 0 to 1 resets every interface's `forwarding` to 1, so the
  three non-transit bridges route again until `sysctl -p /etc/sysctl.d/90-akasha-network.conf`
  or the next run.
- Loading `br_netfilter` makes bridged VM-to-VM frames go through the forward chain, where they
  are dropped (the lab breaks, fail-closed). The `host_network` role asserts it is not loaded.

## See what the rules do

```bash
nft list table inet akasha          # counters on every drop and on the masquerade rule
nft list chain inet akasha from_lab
```

## Test with a fake lab VM

Network namespaces only touch the lab bridges; addresses of the campus are read at run time.

```bash
gw=$(ip -4 route show default | awk '{print $3}')
hostip=$(ip -4 -o addr show dev eno1 | awk '{print $4}' | cut -d/ -f1)
ping -c1 -W2 "$gw"                                   # control: the gateway answers the host

ip netns add akt1
ip link add akt1-h type veth peer name akt1-n
ip link set akt1-h master br-transit up
ip link set akt1-n netns akt1
ip -n akt1 addr add 10.255.255.3/29 dev akt1-n
ip -n akt1 link set lo up; ip -n akt1 link set akt1-n up
ip -n akt1 route add default via 10.255.255.1

nft list table inet akasha > /tmp/akt-before
ip netns exec akt1 ping -c2 -W2 1.1.1.1                              # works (NAT)
ip netns exec akt1 timeout 5 bash -c '</dev/tcp/1.1.1.1/443' && echo tcp443 ok
ip netns exec akt1 ping -c2 -W2 10.255.255.1                         # works
ip netns exec akt1 ping -c2 -W2 "$gw"                                # fails
ip netns exec akt1 ping -c2 -W2 "$hostip"                            # fails
ip netns exec akt1 timeout 5 bash -c "</dev/tcp/$hostip/22" || echo ssh-eno1 blocked
ip netns exec akt1 timeout 5 bash -c '</dev/tcp/10.255.255.1/22' || echo ssh-transit blocked
nft list table inet akasha > /tmp/akt-after
diff /tmp/akt-before /tmp/akt-after       # masquerade, blocked_nets and lab_to_host counters grew

# Second layer: a VM on br-mgmt that uses the host as router
ip netns add akt2
ip link add akt2-h type veth peer name akt2-n
ip link set akt2-h master br-mgmt up
ip link set akt2-n netns akt2
ip -n akt2 addr add 10.10.0.250/24 dev akt2-n
ip -n akt2 link set lo up; ip -n akt2 link set akt2-n up
ip -n akt2 route add default via 10.10.0.1 dev akt2-n onlink
ip -n akt2 neigh replace 10.10.0.1 lladdr "$(cat /sys/class/net/br-mgmt/address)" dev akt2-n
nstat -n                                   # reset the deltas
ip netns exec akt2 ping -c2 -W2 1.1.1.1    # fails
nstat IpInAddrErrors                       # grew: dropped by forwarding=0, before netfilter

# Clean up
ip link del akt1-h; ip link del akt2-h; ip netns del akt1; ip netns del akt2
rm -f /tmp/akt-before /tmp/akt-after
```

## Roll back

```bash
systemctl disable akasha-firewall && nft delete table inet akasha
rm /etc/systemd/system/akasha-firewall.service /etc/akasha/firewall.nft && systemctl daemon-reload
```
