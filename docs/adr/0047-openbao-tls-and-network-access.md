---
status: accepted
date: 2026-11-26
decision-makers: dhuy21
---

# OpenBao's TLS listener, its certificate and who may reach it

## Context and Problem Statement

Step 7d-2 opens OpenBao to the lab. Until now it listens on `core`'s loopback only, without
TLS ([ADR-0039](0039-openbao-on-core-bootstrap.md)). Step 7d-1 created the intermediate CA
and its role `server` ([ADR-0046](0046-openbao-pki-intermediate.md)). The next users reach
OpenBao over the network:
* P2: Kolla's password tools and certificates, from the bastion;
* P3: OpenTofu's Transit encryption, from the bastion.

Several points were open:
* the listener layout and TLS settings;
* who issues OpenBao's own certificate, and how it is renewed;
* the firewall;
* how clients trust the root;
* where the admin may log in from.

Facts checked on 2026-11-26:
* **Cluster ports.** Every TCP listener opens a cluster port: its `cluster_address`, or else
  its own address with port + 1. A second listener on the same cluster address logs a bind
  error. Clustering cannot be turned off with Raft. Source: OpenBao v2.7.3,
  `internal/command/server.go`, `InitListeners`; tested.
* **SIGHUP** reloads a TLS listener's certificate without sealing OpenBao. Tested: after a
  re-issue, the served serial changed and OpenBao stayed unsealed.
* **The root's name constraints** forbid `127.0.0.1` and `localhost` in any certificate
  ([ADR-0044](0044-offline-root-ca.md)).
* **`token_bound_cidrs`** of a userpass user applies to its logins and to their tokens. OpenBao
  stores `127.0.0.1/32` as `127.0.0.1`. Tested:
  * from loopback, a login and its token worked;
  * the same token sent through a network listener got "permission denied";
  * a login from another address got "permission denied".
* **Writing a userpass user without `password`** keeps its password. Tested: login still
  worked after the write.
* **Forwarding on `insa`.** It forwards every port from the tailnet to `10.10.0.0/24`
  (`host_firewall_tailnet_to_lab`). Tailscale's policy is the owner's private file.
* **`10.255.255.1` is more than the tailnet.** It is the source of every connection from the
  tailnet *and from `insa` itself*, the school's host (role `router_firewall`).
* **Userpass checks `token_bound_cidrs` after the password.** Source: OpenBao v2.7.3,
  `internal/builtin/credential/userpass/path_login.go`. Two consequences:
  * a wrong password counts towards the user lockout: 5 failures lock the user for 15
    minutes. The lockout is per user, not per source (`internal/vault/request_handling.go`);
  * a right password answers 403, a wrong one 400.

  Anyone who reaches a listener can lock out the only admin.
* **Unauthenticated `generate-root`** is disabled by default on every listener
  (`disable_unauthed_generate_root_endpoints`, `docs/configuration/listener/tcp.mdx`). A
  locked-out admin could not get a new root token without a configuration change.
* **The certificate's location.** The Raft data lives on the data disk, which outlives a
  rebuild of `core` (ADR-0038), and the unit starts only with a non-empty `openbao.hcl`. A
  certificate on the root disk would therefore be lost at each rebuild, and the TLS listener
  could not start without it.
* **Tested** in a Debian 13 container with OpenBao 2.7.3, `10.10.0.12` on its loopback and the
  role's rendered files:
  * the helper refused an empty token;
  * it issued a 1-year certificate for `DNS:core.akasha.internal, IP:10.10.0.12`, with the key
    in a `root:openbao 0640` file;
  * the role's checks passed: certificate valid, TLS verified through the system trust store,
    and TLS 1.2 refused;
  * an OpenTofu apply of the admin's settings through a loopback forward, then an empty plan.

## Decision Drivers

* Nothing secret on the network without TLS; no port opened beyond those needed.
* The CA keys and OpenBao's key never leave their hosts.
* The admin password alone must not be enough from the network.
* Configuration as code where it can be (ADR-0046).

## Considered Options

* **Listeners:**
  * **TLS on 10.10.0.12:8200 and plain loopback**;
  * one TLS listener on every address.
* **Minimum TLS version:** **1.3**; 1.2.
* **Sources of port 8200** (first answer: the bastion and the tailnet; revised after the
  independent review showed what `10.255.255.1` covers):
  * **the bastion only**;
  * the bastion and `10.255.255.1`;
  * all of `br-mgmt`.
* **Where the certificate lives:**
  * **the data disk, with a loopback-only configuration while it is missing**;
  * `/etc`, issued again after each rebuild.
* **Break-glass `generate-root`:**
  * **enabled on loopback**;
  * disabled, enabled by hand when needed.
* **Who issues OpenBao's certificate:**
  * **a helper on `core`**;
  * OpenTofu, which would put the key in its state.
* **Renewal:**
  * **by hand, one year, a check that fails within 30 days**;
  * a timer on `core` with a token of its own.
* **The admin's login address:**
  * **127.0.0.1 only**;
  * 127.0.0.1 and the tailnet;
  * no limit.
* **How it is set:** **OpenTofu**; a command in the runbook.
* **Trust store:**
  * **a new role `lab_trust`**;
  * a switch in `lab_client`.

## Decision Outcome

Chosen by the owner on 2026-11-26 (the options in bold). The sources, the certificate's
location and the break-glass were chosen after the independent review.

* **Listeners**, in `openbao.hcl` (role `openbao`; `host_vars/core.yml` sets
  `openbao_tls_address`):
  * loopback `127.0.0.1:8200`, without TLS, as before. Used by the helpers, by the admin over
    SSH, and by OpenTofu's tunnel. `disable_unauthed_generate_root_endpoints = false` there
    only: a locked-out admin gets a new root token from two shares, over SSH, without a
    restart;
  * `10.10.0.12:8200` with TLS:
    * `tls_min_version = "tls13"`;
    * certificate `/srv/openbao/tls/openbao.crt` (leaf and intermediate), key
      `openbao.key` (root:openbao 0640), on the data disk;
    * written only once the certificate exists. Until then OpenBao runs on loopback, and the
      run ends asking for `akasha-bao-tls`. A rebuild of `core` keeps the certificate;
    * its cluster port on `127.0.0.1:8202`, so that nothing but 8200 listens on the lab
      address;
  * `api_addr = https://core.akasha.internal:8200`.
* **The certificate.** `akasha-bao-tls`, run as root on `core` with the admin's token on
  stdin:
  * asks the role `server` for `core.akasha.internal` and `10.10.0.12`, for one year;
  * verifies the chain against the system trust store and that the key matches;
  * replaces both files, then reloads OpenBao.

  The token is revoked when the helper ends. The role checks that the certificate is valid
  for 30 more days; renewal is the same command. The change of listeners needs a restart and an
  unseal by hand (ADR-0039).
* **Firewall of `core`** (`vm_firewall_tcp_services`): TCP 8200 from `10.10.0.10/32`, the
  bastion, only. The laptop reaches OpenBao through SSH to `core`'s loopback, and checks TLS
  through the bastion.
* **Trust:** the role `lab_trust` installs `infra/pki/akasha-root-ca.crt` in
  `/usr/local/share/ca-certificates` and runs `update-ca-certificates`, on the bastion and
  `core`. The laptop does not trust the root: OpenTofu goes through the tunnel, and checks use
  `--cacert`.
* **The admin.** The stack `openbao` writes the token settings of the user `admin` through
  `vault_generic_endpoint`:
  * `token_bound_cidrs = ["127.0.0.1"]`;
  * policy `admin`, TTL 1 h, at most 4 h, service tokens;
  * no `password`, so it never reaches the state; `disable_delete`, so the user is never
    deleted.

### Consequences

* Good, because the lab reaches OpenBao over TLS 1.3 only, with a certificate from its own PKI
  and verified against the offline root.
* Good, because the admin's password, even leaked, does not log in from the network.
* Good, because only port 8200 is open, to the bastion alone; neither `insa` nor the tailnet
  can try the admin's password.
* Bad, because the certificate must be renewed by hand every year. The role fails 30 days
  before expiry, but only when it runs.
* Bad, because the change of listeners needs a restart and an unseal, as will any later
  listener change.
* Bad, because loopback stays without TLS. Any process on `core` can reach the API there; it
  still needs a token.
* Bad, because clients other than the bastion and `core` will need `lab_trust` and a firewall
  source of their own (P2 to P5). Each new source can lock the admin out with wrong passwords:
  the admin stays reachable through loopback, and the lockout ends after 15 minutes.
* Bad, because Python `requests` and `httpx` in virtual environments use certifi, not the
  system store: Kolla's tools on the bastion need `REQUESTS_CA_BUNDLE` (P2).
* Bad, because any process on `core` can start or cancel a `generate-root` attempt on loopback.
  It still needs two shares to get a token.
* Bad, because the key and the certificate are replaced one after the other. A restart at that
  instant would find a mismatched pair (accepted: the window is a few milliseconds).

### Confirmation

On `core` and the bastion:
* runs of `core.yml` and `bastion.yml` end with `changed=0`;
* the role's checks pass:
  * listeners on 10.10.0.12:8200 and loopback only;
  * certificate valid, key `root:openbao 0640`;
  * TLS 1.3 verified, TLS 1.2 refused;
* from the bastion, `curl https://core.akasha.internal:8200/v1/sys/health` verifies through
  the system trust store;
* from another lab VM, the port times out (dropped);
* an admin login through the TLS listener, from the bastion, is refused, and one on `core`'s
  loopback works;
* the unauthenticated `generate-root` status answers on loopback, and not over TLS;
* a second plan of the stack `openbao` shows no changes.

## More Information

* Runbooks: [core.md](../runbooks/core.md) ("OpenBao's certificate", "Reach OpenBao over
  TLS"), [openbao-pki.md](../runbooks/openbao-pki.md).
* OpenBao v2.7.3: `internal/command/server.go` (`InitListeners`); TCP listener options
  (`website/content/docs/configuration/listener/tcp.mdx`).
