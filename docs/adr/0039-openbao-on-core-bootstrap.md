---
status: accepted
date: 2026-11-24
decision-makers: dhuy21
---

# OpenBao on core: pinned package, localhost until its initialisation, and a host firewall

## Context and Problem Statement

[ADR-0011](0011-openbao-secrets-and-pki.md) puts OpenBao on `core`, with integrated Raft
storage and a manual Shamir unseal. [ADR-0019](0019-certificate-management.md) keeps an
offline root CA that signs an intermediate CA inside OpenBao. Step 6c-2 installs OpenBao;
step 7 initialises it. Several points were open:

* **TLS.** OpenBao is the lab's future certificate authority, yet it needs a certificate of
  its own before its PKI exists.
* **Install source.** OpenBao is not in Debian's archive.
* **versitygw.** It shares `core` with OpenBao (ADR-0012), but nothing uses it before P4, and
  it should be served with a certificate from OpenBao's PKI.
* **Exposure.** VMs on the same bridge (`br-mgmt`) reach `core` directly, without the router's
  firewall.

Facts checked on 2026-11-24:

* OpenBao 2.7.3 was published at 2026-11-19T19:25:54Z (GitHub API), so the 6-day cooldown of
  ADR-0022 ends at 2026-11-25T19:26Z.
* **Signatures.** Its `checksums.txt` carries a valid GPG signature by key
  `66D1 5FDD 8728 7219 C8E1 5478 D200 CD70 2853 E6D0`. The key file is the same,
  `openbao-gpg-pub-20240618.asc`, in the 2.6.6, 2.7.2 and 2.7.3 releases, and OpenBao's
  install documentation (https://openbao.org/docs/install/, a channel other than GitHub)
  shows the same primary key fingerprint. Its sigstore certificate names the signer as
  `https://github.com/openbao/openbao/.github/workflows/release.yml@refs/heads/release/2.7.x`.
  The GPG signature and the certificate's identity were VERIFIED; the sigstore signature
  itself was not checked (no cosign in the pinned toolchain).
* **The package.** `openbao_2.7.3_linux_amd64.deb` has SHA-256 `0800c714…e290b935`. Read
  from the package itself:
  * it creates the `openbao` user and a self-signed certificate in `/opt/openbao/tls`;
  * it neither enables nor starts the service;
  * its example configuration uses `pebbledb` and a TLS listener on `0.0.0.0:8200`;
  * its unit keeps only `CAP_SYSLOG`, with `Restart=on-failure`.
* **Behaviour.** Measured in a Debian 13 container with the configuration below, an
  uninitialised OpenBao:
  * listens on `127.0.0.1:8200` only (the cluster port opens later);
  * makes `bao status` exit with 2 (sealed), reporting `storage_type` `raft` and `type`
    `shamir`.

## Decision Drivers

* No secret may cross the network in clear text, the unseal shares above all.
* Install only what was verified, the same way every time.
* Do not run a service before it has a user and its certificate.
* `core` holds every secret: it needs a second layer of filtering behind the router.

## Considered Options

* **TLS:**
  * **localhost only, without TLS, until step 7**, with the initialisation over SSH on `core`;
  * create the offline root CA now and serve TLS on the network;
  * serve a temporary self-signed certificate on the network.
* **Install source:** the official `.deb` pinned by version and SHA-256, or a binary tarball
  with a hand-written unit.
* **versitygw:** install it now (localhost only), or defer it until it has a certificate and
  a user.
* **Host firewall on `core`:** now, or together with TLS in step 7.

## Decision Outcome

Chosen by the owner on 2026-11-24: localhost until step 7, defer versitygw, host firewall
now. The pinned official package is part of the approved plan.

* **The role `openbao`:**
  * refuses a release younger than the cooldown, from the pinned `published_at`;
  * creates the `openbao` user and group with a **fixed uid and gid (950)** before the
    package (whose preinst then skips its own `useradd`). The data lives on a disk that
    outlives the VM (ADR-0038), so a rebuilt VM must own it under the same ids;
  * downloads the `.deb` of the pinned version and installs it only if its SHA-256 matches
    (`get_url` checksum), keeping our configuration on upgrades (`force-confold`);
  * makes `/etc/openbao` and `openbao.env` root's, readable by the group `openbao` (the
    postinst gives them to the service user);
  * writes `/etc/openbao/openbao.hcl`:
    * `storage "raft"` in `/srv/openbao/raft` (`node_id` `core`, owner `openbao`, mode 0700),
      on the data disk (ADR-0038);
    * a listener on `127.0.0.1:8200` with `tls_disable` and cluster address
      `127.0.0.1:8201`;
    * `api_addr` and `cluster_addr` on localhost;
    * `ui = false`;
  * adds a drop-in with `RequiresMountsFor=/srv/openbao`, so OpenBao never starts on the
    root disk;
  * enables and starts the service;
  * checks that the **running server** (the `version` of `bao status`, not the binary on
    disk) is the pinned version, listens on localhost only, uses Raft, has its data owned by
    950:950, and is uninitialised and sealed (or initialised, after a rebuild that kept the
    data);
  * **never restarts an initialised OpenBao by itself**, because a restart seals it. It
    restarts only when the running server reports `initialized: false`, or when nothing
    runs. A state it cannot read counts as initialised. When the package or the
    configuration of such an OpenBao changes, the role stops and asks for a restart and an
    unseal by hand.
* **Step 7** initialises OpenBao on `core` over SSH (`BAO_ADDR=http://127.0.0.1:8200`), so the
  unseal shares never cross the network. It also designs the root CA and OpenBao's own
  certificate, then opens the port on purpose.
* **versitygw** is deferred until OpenBao's PKI can serve it a certificate, and a user exists
  (P4: etcd snapshots, CloudNativePG). ADR-0012 is unchanged otherwise.
* **The host firewall** on `core` (role `vm_firewall`, loaded commit confirmed by the shared
  role `nft_commit`, ADR-0037):
  * `input` drops by default;
  * it accepts loopback, established traffic, ping from `10.10.0.0/24` and the tailnet, and
    **SSH only from the bastion (`10.10.0.10/32`) and the tailnet (`10.255.255.1/32`)**. The
    owner chose this on 2026-11-24 as the default of every lab VM: the controller and the
    computes cannot SSH into `core`;
  * it drops IPv6 and forwards nothing;
  * TCP services are listed explicitly (none yet).

### Consequences

* Good, because nothing secret exists or travels in clear before TLS exists.
* Good, because exactly the verified package is installed.
* Good, because a missing data disk, or a configuration change on an unsealed OpenBao, fails
  visibly instead of silently.
* Bad, because OpenBao is not in Debian's archive, so unattended upgrades never patch it.
  Every patch is a new pin, verified by hand (runbook `core.md`; ADR-0042).
* Bad, because nothing can use OpenBao before step 7.
* Bad, because the package's self-signed certificate in `/opt/openbao/tls` stays on disk,
  unused, until step 7 replaces it.

### Confirmation

Step 6c-2:
* the router's playbook reports `changed=0` after the commit-confirmed logic moved into
  `nft_commit`;
* on `core`, every check passes and a second run reports `changed=0`;
* from the bastion, `10.10.0.12:8200` is unreachable.

### Implementation (2026-11-24)

Applied from PR #69.

* **Cooldown exception, granted by the owner.** OpenBao 2.7.3 was installed 4.8 days after its
  release, before the 6-day cooldown of ADR-0022 ended. 2.7.3 is a security release
  (GHSA-fgmw-h9wp-wc7g, GHSA-h8fh-pmch-cjww). Its alternative, 2.7.2, carries those known
  issues. The exception was given on the command line (`-e openbao_cooldown_days=4`) for this
  one run; the role's default stays 6 days.
* **Router.** After the commit-confirmed logic moved into `nft_commit`, the router's playbook
  reported `changed=0`.
* **core.** The first real run loaded the host firewall commit confirmed and installed and
  started OpenBao; the next run reported `changed=0`, and so did a later dry run.
  * `bao status`: version 2.7.3, Shamir seal, not initialised, sealed, Raft storage.
  * `bao` listens on `127.0.0.1:8200` only.
  * `openbao` has uid and gid 950.
  * The `input` chain drops by default and accepts SSH from 10.10.0.10 and 10.255.255.1 only.
  * From the bastion, a connection to 10.10.0.12:8200 timed out (dropped, not refused), and
    the kernel log showed `akasha drop input` for its three SYNs.
* **Defects found on the way, fixed in the same pull request:**
  * the cooldown read from `-e` was a string;
  * a dry run tried to install a package it had not downloaded.

## More Information

* The independent review of the plan and the code (2026-11-24) found no blocker. Its
  findings were fixed before anything ran:
  * runs limited to other tags failed on the shared role's argument check;
  * the first dry run failed on the download;
  * an unreadable state would have allowed a restart;
  * a version bump would not have restarted the server;
  * the uid was not fixed;
  * the bump runbook was incomplete;
  * the cooldown was not enforced.
* OpenBao docs: configuration and Raft storage (https://openbao.org/docs/configuration/,
  https://openbao.org/docs/configuration/storage/raft/); install and GPG verification
  (https://openbao.org/docs/install/).
* The configuration page no longer lists `mlock`, consistent with the unit's capabilities
  (INFERRED).
* Note for step 7: inside the VM, `core` resolves to `127.0.1.1` (cloud-init
  `manage_etc_hosts`). Network-facing addresses must use 10.10.0.12 or
  `core.akasha.internal` through the router's DNS.

## Updates

* 2026-11-24: Renovate now opens a pull request when a new release of OpenBao is out, through a
  regex custom manager on the version line ([ADR-0042](0042-updates-of-pinned-release-binaries.md),
  open question B16). The SHA-256, the publication time and the signature check stay manual.
* 2026-11-26 (step 7d-2, [ADR-0047](0047-openbao-tls-and-network-access.md)): OpenBao also
  listens on `10.10.0.12:8200` with TLS 1.3 and a certificate from its own PKI. The firewall of
  `core` accepts that port from the bastion only. The loopback listener without TLS stays.
