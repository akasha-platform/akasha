# Open questions and pending verifications

Everything here is **not decided or not proven yet**. Each item names the phase where it must
be resolved. When resolved, move the answer into the relevant ADR (or a new one) and delete the
item here.

## A. Tests that must pass before relying on a design choice

| # | Test | Why | Phase |
|---|---|---|---|
| A1 | Cold boot of all VMs (`virsh destroy`) — does single-node Galera restart alone or need `kolla-ansible mariadb-recovery`? | Kolla design note and Galera docs disagree | P2 |
| A2 | Real memory use of `os-ctl01` and per-compute overhead (`docker stats`, `free`, `virsh dommemstat`); bastion memory during `kolla-ansible deploy` (lower `forks` if needed) and during a sandboxed `tofu` run with the OpenStack provider (ADR-0032) | Controller may need more than 8 GB; sets `reserved_host_memory_mb`; 768 MiB bastion (ADR-0030) is ESTIMATED | P2 |
| A4 | barman-cloud (CloudNativePG) and K3s `etcd-s3` uploads to versitygw | Inferred compatibility | P4–P5 |
| A5 | `kolla-readpwd` / `kolla-writepwd` against OpenBao KV v2 | Written for HashiCorp Vault | P2 |
| A6 | cert-manager Vault issuer against OpenBao | Not documented by cert-manager | P5 |
| A7 | OpenTofu `openbao` key provider against OpenBao 2.7 (Transit keys for the L2 and L3 states, ADR-0032) | Documented against Vault 1.14 | P3 |
| A8 | External Secrets Operator Vault provider against OpenBao (JWT auth) | Tested upstream only with old versions | P5 |
| A9 | Free page reporting end to end (K3s VM → compute → host) | Inferred only | P1/P4 |
| A10 | KSM A/B: profit, ksmd CPU, Galera/RabbitMQ/etcd latency with KSM on vs off | No published nested benchmark | P7 |
| A11 | Live migration of a K3s VM between computes; evacuation; expected "No valid host" for hard anti-affinity | Failure drills | P7 |
| A12 | Restore drills: etcd snapshot, CloudNativePG PITR, OpenBao raft snapshot, restic from AWS | A backup is only real once restored | P7 |
| A18 | An OpenStack instance gets the lab's NTP server from OVN DHCP (the rest of A18 is settled: ADR-0036 Updates, 2026-11-27) | Assumption of ADR-0029/ADR-0036 for L2 | P2 |

## B. Decisions deliberately deferred

| # | Decision | Options | Phase |
|---|---|---|---|
| B1 | RAM cut-downs if K3s guests lack memory | shorter metrics/log retention · one PostgreSQL instance for prod · merge CI node into workers · defer/drop Octavia (NodePort) · replace Kyverno with native ValidatingAdmissionPolicy (~0.45 GB, loses image-signature checks) | after A2 (P4) |
| B2 | Tenant MTU | 1442 (default, 1500 underlay) · ≈ 8942 (`path_mtu` 9000 on `br-tun`); pod MTU = tenant − 50 | P2 |
| B4 | One VIP or two (internal/external) for the OpenStack APIs | two VIPs need two certificates and an OPNsense rule | P2 |
| B5 | Pin kolla-ansible by PyPI release (22.2.0) or by `stable/2026.1` commit SHA | | P2 |
| B6 | Add `net01` (dedicated network node) | only if ≥ 1.5 GB spare after A2 | P7 |
| B8 | Root disks of K3s VMs; metadata delivery | Cinder boot-from-volume (no disk copy on live migration, uses the 120 G Cinder LV) · local ephemeral on the computes · config drive (blocks block migration) vs metadata service | P3/P4 |
| B12 | SSH authentication of the CI runner to the bastion wrapper (ADR-0032): the OpenBao SSH CA is out of the runner's reach and Tailscale SSH would bypass `ForceCommand`; a static low-value key as a GitHub secret is the remaining option, a long-lived secret | static key · other | P3 |
| B13 | Offline backup of the OpenBao Transit keys that encrypt the L2/L3 states: exportable keys with plaintext backup (cannot be turned off later) or rely on the off-site OpenBao raft snapshots plus the unseal shares | exportable key backup · raft snapshots only | P3 |
| B14 | Off-AWS copy of the L2/L3 states, like ADR-0031's for L0, or none (they can be rebuilt by import) | copy after apply · none | P3 |
| B15 | Tailnet policy: the CI tag may reach only the bastion's SSH port (change to the owner's tailnet policy, ADR-0008 step 4c) | yes · other | P3 |

## C. Questions never discussed yet

| # | Question | Phase |
|---|---|---|
| C1 | Should the NovaShop demo be reachable from the Internet (e.g. a tunnel) for the portfolio, or only through Tailscale? | P6 |
| C2 | Is there a real domain name (for public TLS / DNS-01), or only `akasha.internal`? | P5 |
| C3 | Where do alerts go (Alertmanager receiver: email, Discord, …)? Retention targets for metrics and logs? | P5/P7 |

## D. Facts to re-check right before use

Versions and prices move fast; the research notes date from 2026-11-08. Re-check at least:
kolla-ansible 22.x, K3s channel, cloud-provider-openstack chart, ARC, Argo CD, OpenBao,
`dmacvicar/libvirt`, OpenStack provider, Loki chart changes, AWS S3 pricing.
