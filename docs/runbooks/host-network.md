# Host network (lab bridges on `insa`)

Design: [ADR-0008](../adr/0008-host-networking-and-access.md). Managed by the Ansible role
`host_network` (`infra/ansible/playbooks/host.yml`, tag `network`). Commands run on `insa` as
root unless stated otherwise.

## Check the bridges

```bash
ip -br link show type bridge          # br-transit, br-mgmt, br-tun, br-ext
ip -d link show br-tun | grep -o 'mtu [0-9]*'
ip -6 addr show dev br-mgmt           # must print nothing
nmcli -f DEVICE,STATE device | grep '^br-'   # all "unmanaged"
cat /proc/sys/net/ipv4/ip_forward     # 1
```

## A bridge is missing

- **Symptom:** a VM fails to start ("Cannot get interface MTU on 'br-…'") or has no network.
- **Diagnosis:** `ip link show br-…`; `journalctl -b -u networking`; `ifquery br-…` shows the
  stanza ifupdown knows.
- **Mitigation:** `ifup br-…`, then restart the VMs that use it (libvirt does not re-attach
  taps of `type='bridge'` interfaces).

## Change the definition of an existing bridge

`ifdown` deletes the bridge (`brctl delbr`) and every VM tap attached to it loses its link.
The role never does it on its own; it prints a warning when the definition changed.

```bash
sudo virsh list --all                       # find the VMs on that bridge (virsh domiflist <vm>)
sudo virsh shutdown <vm>                    # each VM attached to the bridge
ifdown br-… && ifup br-…
sudo virsh start <vm>
```

## Overlay MTU stays at 9000

The kernel lowers a bridge to its smallest port MTU unless the MTU was set by the user.
Check that `br-tun` keeps 9000 after a port comes and goes:

```bash
ip tuntap add dev mtutest0 mode tap && ip link set mtutest0 master br-tun
ip link del mtutest0
cat /sys/class/net/br-tun/mtu               # expect 9000
```

## NetworkManager took a bridge

- **Symptom:** `nmcli device` shows a lab bridge as `connected` or `connected (externally)`.
- **Fix:** check `/etc/NetworkManager/conf.d/90-akasha-unmanaged.conf`, then
  `nmcli general reload conf`.
