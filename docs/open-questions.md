# Open questions and pending verifications

Everything here is **not decided or not proven yet**. Each item names the phase where it must
be resolved. When resolved, move the answer into the relevant ADR (or a new one) and delete the
item here.

## A. Tests that must pass before relying on a design choice

| # | Test | Why | Phase |
|---|---|---|---|
| A1 | Cold boot of all VMs (`virsh destroy`) — does single-node Galera restart alone or need `kolla-ansible mariadb-recovery`? | Kolla design note and Galera docs disagree | P2 |
| A2 | Real memory use of `os-ctl01` and per-compute overhead (`docker stats`, `free`, `virsh dommemstat`); bastion memory during `kolla-ansible deploy` (lower `forks` if needed) | Controller may need more than 8 GB; sets `reserved_host_memory_mb`; 1 GB bastion is ESTIMATED | P2 |
| A3 | versitygw: two concurrent `If-None-Match: *` writes → exactly one HTTP 412 | OpenTofu `use_lockfile` depends on it | P1 |
| A4 | barman-cloud (CloudNativePG) and K3s `etcd-s3` uploads to versitygw | Inferred compatibility | P4–P5 |
| A5 | `kolla-readpwd` / `kolla-writepwd` against OpenBao KV v2 | Written for HashiCorp Vault | P2 |
| A6 | cert-manager Vault issuer against OpenBao | Not documented by cert-manager | P5 |
| A7 | OpenTofu `openbao` key provider against OpenBao 2.7 | Documented against Vault 1.14 | P1/P3 |
| A8 | External Secrets Operator Vault provider against OpenBao (JWT auth) | Tested upstream only with old versions | P5 |
| A9 | Free page reporting end to end (K3s VM → compute → host) | Inferred only | P1/P4 |
| A10 | KSM A/B: profit, ksmd CPU, Galera/RabbitMQ/etcd latency with KSM on vs off | No published nested benchmark | P7 |
| A11 | Live migration of a K3s VM between computes; evacuation; expected "No valid host" for hard anti-affinity | Failure drills | P7 |
| A12 | Restore drills: etcd snapshot, CloudNativePG PITR, OpenBao raft snapshot, restic from AWS | A backup is only real once restored | P7 |
| A13 | Design and test restic on AWS S3 with Object Lock: bucket versioning, retention mode, which credential runs `forget/prune`, cost | Object Lock needs versioning; prune deletes objects; the "no-delete key" idea came from B2 | P1 |
| A14 | OpenBao self-init (`initialize` stanza) behaviour with Shamir unseal | Self-init is documented mainly with auto-unseal | P1 |
| A15 | Host checks after setup: `virsh dumpxml` shows the requested `cpu.mode` (provider issue #1344); the per-VM `oom_score_adj` once VMs run. Checked on 2026-11-17 (ADR-0016): cgroup2 has `memory_recursiveprot`; libvirtd's `OOMScoreAdjust=0`, so QEMU inherits 0; zswap off, zpool `zsmalloc` (built in), compressor `lzo` | Each is an assumption of the host design | P1 (step 6) |
| A17 | After the next host reboot: the four lab bridges come back (`ip -br link show type bridge`), unmanaged by NetworkManager, no IPv6 on them, `ip_forward=1`, libvirt `default` network inactive, `akasha-firewall` active with table `inet akasha` loaded, `forwarding` 1/0/0/0 on the bridges, `tailscale debug prefs` still advertises both lab routes, `ip route show 10.10.0.0/24` and `10.20.0.0/24` via 10.255.255.2 dev br-transit, tailscaled log says "default choosing iptables", the guard rule is in `nft list chain inet akasha forward` | Checked only on the running host (ADR-0008 step 4a) | P1 |
| A18 | Lab time chain once the router exists (ADR-0029): htpdate steps the clock before chronyd serves; offset of the router and of an L1 VM against UTC; the `ptp_kvm` reading of the host offset; behaviour when every HTTPS source is unreachable; an OpenStack instance gets the NTP server from OVN DHCP | Each is an assumption of ADR-0029 | P1 (step 6) |
| A19 | Does the campus let TCP 80 out (Debian mirrors and other tools use `http://`)? Test from a lab namespace on `br-transit`: `curl -sI http://deb.debian.org` | Only DNS and HTTPS were tested (step 4b) | P1 (before step 6) |
| A20 | Drift rate of the host clock: second offset measurement against an NTP-synced laptop (first: −18.0 s on 2026-11-17 09:48 UTC) | Shows how fast the host departs from UTC; the lab does not depend on it (ADR-0029) but `ptp_kvm` monitoring does | P1 |
| A22 | libvirtd on `insa` is socket-activated (`libvirtd.service` inactive, `libvirtd.socket` active on 2026-11-17): after a host reboot, do domains marked autostart (the router) start without anything connecting to libvirt? | ADR-0028 boot order and the router's autostart depend on it | P1 (step 6) |
| A23 | libvirt provider 0.9.9 and the local temp directory (ADR-0031): with `ignore_changes = [create]` on volumes built from content, a plan after `/tmp` is cleared (reboot) or from another machine must not replace any volume nor stop any VM; a state-loss drill (import blocks) must end with a plan that destroys nothing; S3 lock: two terminals planning at once get one lock error | Without it, a routine plan can stop `core` | P1 (step 6) |

## B. Decisions deliberately deferred

| # | Decision | Options | Phase |
|---|---|---|---|
| B1 | RAM cut-downs if K3s guests lack memory | shorter metrics/log retention · one PostgreSQL instance for prod · merge CI node into workers · defer/drop Octavia (NodePort) · replace Kyverno with native ValidatingAdmissionPolicy (~0.45 GB, loses image-signature checks) | after A2 (P4) |
| B2 | Tenant MTU | 1442 (default, 1500 underlay) · ≈ 8942 (`path_mtu` 9000 on `br-tun`); pod MTU = tenant − 50 | P2 |
| B4 | One VIP or two (internal/external) for the OpenStack APIs | two VIPs need two certificates and an OPNsense rule | P2 |
| B5 | Pin kolla-ansible by PyPI release (22.2.0) or by `stable/2026.1` commit SHA | | P2 |
| B6 | Add `net01` (dedicated network node) | only if ≥ 1.5 GB spare after A2 | P7 |
| B8 | Root disks of K3s VMs; metadata delivery | Cinder boot-from-volume (no disk copy on live migration, uses the 120 G Cinder LV) · local ephemeral on the computes · config drive (blocks block migration) vs metadata service | P3/P4 |
| B9 | Host-wide IPv6 on `insa`: a pre-existing `/etc/sysctl.d/99-disable-ipv6.conf` (not from akasha) holds `sysctl -w …` shell lines, which `systemd-sysctl` cannot parse, so IPv6 stays on (checked 2026-11-14); the lab bridges have IPv6 off either way (ADR-0008) | leave as is · delete the file · disable IPv6 host-wide in valid syntax (affects Tailscale IPv6 and `::1`) | P1 |

## C. Questions never discussed yet

| # | Question | Phase |
|---|---|---|
| C1 | Should the NovaShop demo be reachable from the Internet (e.g. a tunnel) for the portfolio, or only through Tailscale? | P6 |
| C2 | Is there a real domain name (for public TLS / DNS-01), or only `akasha.internal`? | P5 |
| C3 | Where do alerts go (Alertmanager receiver: email, Discord, …)? Retention targets for metrics and logs? | P5/P7 |
| C6 | Acceptable reboot window for host kernel updates (unattended upgrades never reboot automatically) | P1 |
| C7 | AWS account, free-tier terms and expected monthly cost for off-site backups | P1 |
| C8 | Node key expiry of `insa` in the tailnet (expires 2027-03-21, read on 2026-11-17): expiry drops `insa` from the tailnet and locks the owner out until a log-in on site; Tailscale advises disabling expiry on servers and subnet routers. Depends on when the semester (and the loan of `insa`) ends | P1 |

## D. Facts to re-check right before use

Versions and prices move fast; the research notes date from 2026-11-08. Re-check at least:
kolla-ansible 22.x, K3s channel, cloud-provider-openstack chart, ARC, Argo CD, OpenBao,
`dmacvicar/libvirt`, OpenStack provider, Loki chart changes, AWS S3 pricing.
