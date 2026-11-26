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
* **Sources of port 8200:**
  * **the bastion and the tailnet**;
  * the bastion only;
  * all of `br-mgmt`.
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

Chosen by the owner on 2026-11-26 (the options in bold).

* **Listeners**, in `openbao.hcl` (role `openbao`; `host_vars/core.yml` sets
  `openbao_tls_address`):
  * loopback `127.0.0.1:8200`, without TLS, as before. Used by the helpers, by the admin over
    SSH, and by OpenTofu's tunnel;
  * `10.10.0.12:8200` with TLS:
    * `tls_min_version = "tls13"`;
    * certificate `/etc/openbao/tls/openbao.crt` (leaf and intermediate), key
      `openbao.key` (root:openbao 0640);
    * its cluster port on `127.0.0.1:8202`, so that nothing but 8200 listens on the lab
      address;
  * `api_addr = https://core.akasha.internal:8200`.
* **The certificate.** `akasha-bao-tls`, run as root on `core` with the admin's token on
  stdin:
  * asks the role `server` for `core.akasha.internal` and `10.10.0.12`, for one year;
  * verifies the chain against the system trust store and that the key matches;
  * replaces both files, then reloads OpenBao.

  The role checks that the certificate is valid for 30 more days; renewal is the same command.
  The first run with `openbao_tls_address` set stops until the certificate exists. The
  change of listeners then needs a restart and an unseal by hand (ADR-0039).
* **Firewall of `core`** (`vm_firewall_tcp_services`): TCP 8200 from `10.10.0.10/32` (bastion)
  and `10.255.255.1/32` (the tailnet's address on the lab side).
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
* Good, because only port 8200 is open, to two sources.
* Bad, because the certificate must be renewed by hand every year. The role fails 30 days
  before expiry, but only when it runs.
* Bad, because the change of listeners needs a restart and an unseal, as will any later
  listener change.
* Bad, because loopback stays without TLS. Any process on `core` can reach the API there; it
  still needs a token.
* Bad, because clients other than the bastion and `core` will need `lab_trust` and a firewall
  source of their own (P2 to P5).

### Confirmation

On `core` and the bastion:
* runs of `core.yml` and `bastion.yml` end with `changed=0`;
* the role's checks pass:
  * listeners on 10.10.0.12:8200 and loopback only;
  * certificate valid, key `root:openbao 0640`;
  * TLS 1.3 verified, TLS 1.2 refused;
* from the bastion, `curl https://core.akasha.internal:8200/v1/sys/health` verifies through
  the system trust store;
* from the laptop, `curl --cacert infra/pki/akasha-root-ca.crt https://10.10.0.12:8200/…`
  answers;
* from another lab VM, the port times out (dropped);
* an admin login through the TLS listener is refused, and one on `core`'s loopback works;
* a second plan of the stack `openbao` shows no changes.

## More Information

* Runbooks: [core.md](../runbooks/core.md) ("OpenBao's certificate", "Reach OpenBao over
  TLS"), [openbao-pki.md](../runbooks/openbao-pki.md).
* OpenBao v2.7.3: `internal/command/server.go` (`InitListeners`); TCP listener options
  (`website/content/docs/configuration/listener/tcp.mdx`).
