# Tailscale subnet routes to the lab (`insa`)

Design: [ADR-0008](../adr/0008-host-networking-and-access.md) (step 4c) and
[ADR-0027](../adr/0027-guest-on-the-school-host.md). `insa` advertises the lab networks
10.10.0.0/24 (management, APIs) and 10.20.0.0/24 (floating IPs) to the owner's tailnet; only
the owner's laptop may use them.

Tailscale on `insa` is the owner's only remote access path and belongs to the owner, so it is
configured by hand from this runbook, not by an Ansible role. Keep an SSH session to `insa`
open while changing anything below.

## What is configured

| Where | Setting |
|---|---|
| `insa` | `sudo tailscale set --advertise-routes=10.10.0.0/24,10.20.0.0/24` (SNAT kept on, the default) |
| Admin console → Machines → `insa` → Edit route settings | both routes approved by hand (no `autoApprovers`) |
| Admin console → Access controls | the policy below |
| Laptop (Linux) | `sudo tailscale set --accept-routes` |
| Other devices | Linux: keep `--accept-routes` off. Phones and other OSes accept routes by default: turn off "Use Tailscale subnets". The policy denies them the lab either way. |

`--advertise-routes` replaces the whole list: always pass both routes. `tailscale set` may warn
about IPv6 forwarding or UDP GRO on the uplink; the routes are IPv4 only and IPv4 forwarding is
set by the `host_network` role, so these warnings do not apply.

## Tailnet policy

The real policy holds Tailscale addresses and the owner's login: keep it in
`~/akasha-private/` and never commit it. Template:

```jsonc
{
	"hosts": {
		"akasha-laptop": "<laptop-tailscale-ip>",
		"akasha-host":   "<insa-tailscale-ip>",
		"akasha-other": "<other-device-tailscale-ip>",
	},

	"grants": [
		// All the owner's devices reach each other, as with the default policy.
		{"src": ["autogroup:member"], "dst": ["autogroup:self"], "ip": ["*"]},
		// Only the laptop reaches the lab networks (subnet routes advertised by insa).
		{"src": ["akasha-laptop"], "dst": ["10.10.0.0/24", "10.20.0.0/24"], "ip": ["*"]},
	],

	// Unchanged from the default policy.
	"ssh": [
		{
			"action": "check",
			"src":    ["autogroup:member"],
			"dst":    ["autogroup:self"],
			"users":  ["autogroup:nonroot", "root"],
		},
	],

	// Checked on every save: a failing test makes the console refuse the whole policy.
	"tests": [
		{"src": "akasha-laptop", "accept": ["akasha-host:22", "10.10.0.1:8080", "10.20.0.1:8080"]},
		{"src": "akasha-other", "deny": ["10.10.0.1:8080", "10.20.0.1:8080"]},
		{
			"src":    "<owner-login>",
			"accept": ["akasha-host:22", "akasha-other:22"],
			"deny":   ["10.10.0.1:8080", "10.20.0.1:8080"],
		},
	],
}
```

Before editing the policy, copy the current one from the console to
`~/akasha-private/tailnet-policy-backup-<date>.hujson`.

## Check

```bash
# insa
tailscale debug prefs | grep -A3 AdvertiseRoutes     # both routes
iptables -t nat -S ts-postrouting                    # MASQUERADE on mark 0x40000/0xff0000
# The packet filter insa received: the lab routes must list only the laptop as source.
sudo tailscale debug netmap | python3 -c 'import json,sys
for r in json.load(sys.stdin).get("PacketFilterRules") or []:
    print(r.get("SrcIPs"), "->", sorted({p.get("IP") for p in r.get("DstPorts") or []}))'

# laptop
ip route show table 52 | grep -E '^10\.(10|20)\.0\.0/24'   # two routes, dev tailscale0
ip route get 10.10.0.1                                       # dev tailscale0 table 52
```

## How a packet goes from the laptop to the lab

laptop → `tailscale0` on `insa` → `ts-forward` marks it, `ts-postrouting` masquerades it to
10.255.255.1 → akasha chain `to_lab` accepts `tailscale0` → 10.10/24, 10.20/24 towards
`br-transit` → lab router 10.255.255.2. The lab therefore needs no route back to the tailnet,
and the akasha chain `from_lab` drops connections opened from the lab towards the tailnet.

## Test with a fake lab router

Run on `insa` as root. Only `br-transit` is touched; everything is removed at the end.

```bash
ip netns add akr
ip link add akr-h type veth peer name akr-n
ip link set akr-h master br-transit up
ip link set akr-n netns akr
ip -n akr link set lo up
ip -n akr addr add 10.255.255.2/29 dev akr-n
ip -n akr addr add 10.10.0.1/32 dev lo
ip -n akr addr add 10.20.0.1/32 dev lo
ip -n akr link set akr-n up
ip -n akr route add default via 10.255.255.1
d=$(mktemp -d); cd "$d"
ip netns exec akr python3 -m http.server 8080 --bind 10.10.0.1 & s1=$!
ip netns exec akr python3 -m http.server 8080 --bind 10.20.0.1 & s2=$!
# laptop: curl -m5 http://10.10.0.1:8080/ ; curl -m5 http://10.20.0.1:8080/
#   both answer; the server log shows the client 10.255.255.1 (SNAT)
nft list chain inet akasha from_lab | tail -3          # note the last "counter ... drop"
ip netns exec akr timeout 5 bash -c '</dev/tcp/<laptop-tailscale-ip>/22' || echo blocked
nft list chain inet akasha from_lab | tail -3          # that counter grew

# Clean up
kill "$s1" "$s2"; cd /; rm -rf "$d"
ip link del akr-h; ip netns del akr
```

## Local network overlaps a lab range

Tailscale's routes live in table 52, looked up before the main table (rule priority 5270). If a
network the laptop joins uses 10.10.0.0/24 or 10.20.0.0/24, its local hosts become unreachable
while `--accept-routes` is on: run `sudo tailscale set --accept-routes=false` there.

## Roll back

```bash
sudo tailscale set --accept-routes=false              # laptop
sudo tailscale set --advertise-routes=                # insa
```

Policy: paste the backup from `~/akasha-private/`, or revert from the console's policy history
(the console is reachable from any browser, independent of the tailnet). Remove the route
approvals under Machines → `insa` → Edit route settings.
