---
status: accepted
date: 2026-11-28
decision-makers: dhuy21
---

# TLS of the OpenStack APIs from OpenBao's PKI, on two VIPs

## Context and Problem Statement

Kolla-Ansible puts every OpenStack API behind HAProxy on `os-ctl01`; keepalived holds the
virtual addresses (VIPs) HAProxy listens on. Without TLS, Keystone's passwords and tokens
cross `br-mgmt` in clear text. Open question B4 asked whether the APIs get one VIP or two
(the architecture overview reserved `10.10.0.100` and `10.10.0.101`). Step 4 of P2 decides it, and how HAProxy
gets its certificate, before the first deployment (step 5).

What Kolla does, read in the source of the pinned commit `d9658dc` (VERIFIED):
* **One VIP** (`kolla_external_vip_address` equal to `kolla_internal_vip_address`, the
  default): HAProxy has no external frontend (`haproxy_enable_external_vip`), and the public
  endpoints are served on the internal VIP. TLS then follows `kolla_enable_tls_internal`.
* **Two VIPs:** HAProxy serves the internal endpoints on one and the public endpoints on the
  other. Both default to the interface `network_interface` (`mgmt`).
* **The internal VIP also carries MariaDB** (`database_address` is the internal FQDN, port
  3306).
* **Certificates:**
  * HAProxy reads one PEM file per VIP: `haproxy-internal.pem` and `haproxy.pem`, each with
    the certificate, its chain and the private key;
  * Kolla copies them from `kolla_certificates_dir` on the deployment host (the bastion) to
    `/etc/kolla/haproxy/` on the controller (`roles/loadbalancer/tasks/copy-certs.yml`);
  * `kolla_certificates_dir` is only read on the deployment host, as a source of copies;
  * with `kolla_copy_ca_into_containers`, the files in `<kolla_certificates_dir>/ca/` go into
    every container's trust store (`roles/service-cert-copy`).
* **`kolla-ansible certificates`** makes its own test CA and writes unencrypted keys. It is
  not used (ADR-0052).

Who calls the APIs:
* **On `br-mgmt`:** the OpenStack services themselves, the bastion (Kolla, the `openstack`
  CLI, OpenTofu at P3), and the laptop through the tailnet.
* **On `br-ext`, from P4:** the K3s VMs, through the OpenStack cloud provider and Cinder's CSI
  driver. The router keeps `ext` → `mgmt` closed until a rule is decided (ADR-0037).

## Decision Drivers

* A K3s VM, or anything on `br-ext`, must never reach MariaDB or an internal-only endpoint.
* Every API call is encrypted and its server authenticated by the lab's root CA (ADR-0044).
* The private key never reaches git or a disk of the laptop or the bastion, like Kolla's
  passwords (ADR-0052).
* Kolla's standard flow, so that upgrades and Kolla's own documentation still apply.
* The operator on the bastion gets no new power to mint certificates.

## Considered Options

* **VIPs:**
  * **two: internal `10.10.0.100`, external `10.10.0.101`**;
  * one: `10.10.0.100` for everything.
* **Where TLS is on:**
  * **between clients and both VIPs**;
  * on the external VIP only;
  * on both VIPs and between HAProxy and the services (back-end TLS).
* **The certificate's key:**
  * **issued by OpenBao's PKI, kept in OpenBao KV, copied to the bastion's tmpfs for a Kolla
    run**, as StackHPC does with its encrypted `haproxy-internal.pem`;
  * generated on `os-ctl01`, never leaving it: OpenBao signs a CSR, and Kolla is told the
    certificates are managed outside it (`kolla_externally_managed_cert`);
  * ACME from OpenBao through Kolla's `letsencrypt` containers, renewed on its own.
* **Who issues it:**
  * **the admin, from the laptop through the tunnel**;
  * the operator on the bastion, through a narrow PKI role.
* **How long it lives:**
  * **one year, with a warning 30 days before**;
  * 90 days.

## Decision Outcome

Chosen by the owner on 2026-11-28 (the options in bold). It answers open question B4.

* **Addresses and names** (Unbound on the router, A and PTR records, role `router_dns`):
  * `api-int.akasha.internal` → `10.10.0.100`, the internal VIP: the services, the bastion,
    MariaDB;
  * `api.akasha.internal` → `10.10.0.101`, the external VIP: the public endpoints only.

  Both VIPs live on `mgmt` of `os-ctl01`; keepalived holds both.
* **Kolla** (`infra/kolla/globals.d/`):
  * `kolla_internal_vip_address`, `kolla_external_vip_address`, `kolla_internal_fqdn`,
    `kolla_external_fqdn` as above;
  * `kolla_enable_tls_internal: true`, `kolla_enable_tls_external: true`; back-end TLS stays
    off. With one controller, HAProxy and the services are on the same VM;
  * `kolla_copy_ca_into_containers: true` and
    `openstack_cacert: /etc/ssl/certs/ca-certificates.crt` (Debian's bundle in the
    containers);
  * `kolla_certificates_dir: /run/akasha-kolla/certificates`, on the tmpfs of ADR-0052. With
    no copy there, Kolla's copy tasks fail and nothing is deployed without TLS.
* **The certificate:**
  * one certificate from the PKI role `server` (ADR-0046):
    * names `api.akasha.internal` (common name) and `api-int.akasha.internal`;
    * IP addresses `10.10.0.100` and `10.10.0.101`;
    * EC P-256, one year;

    It serves both VIPs: `haproxy.pem` and `haproxy-internal.pem` have the same content.
  * **Issued by the admin from the laptop**, through the tunnel of runbook `openbao-pki.md`,
    once a year. OpenBao's answer is piped straight into a KV v2 secret
    `kv/kolla/tls/haproxy` (the certificate, the issuing CA, the key, the expiry). The key
    passes through the laptop's memory only, never its disk.
  * **The operator** may read `kv/kolla/tls/*`, nothing else there: no create, no update. It
    gets no PKI permission.
* **`akasha-kolla-passwords read`** also writes, on the tmpfs:
  * `certificates/haproxy.pem` and `certificates/haproxy-internal.pem`: the certificate, the
    intermediate and the key, mode `0600`;
  * `certificates/ca/akasha-root-ca.crt`: the public root from `infra/pki/`.

  Before writing them, it checks four things:
  * the chain verifies against the root;
  * the key matches the certificate;
  * the certificate holds both names and both addresses;
  * the certificate has not expired. Below 30 days it warns; once expired it refuses.

  `clean` already empties the tmpfs.
* **Renewal**, before the warning becomes a refusal:
  * the admin issues a new certificate into the same secret, a new KV version;
  * then a Kolla run puts it in HAProxy (`read`, then
    `kolla-ansible reconfigure -t loadbalancer`).
* **Unchanged:**
  * the router's `ext` → `mgmt` stays closed. A rule from `br-ext` to `10.10.0.101` on the API
    ports only is proposed at P4, when the K3s VMs need it;
  * the laptop does not trust the root (ADR-0047). The `openstack` CLI runs on the bastion,
    which does.

### Consequences

* Good, because nothing on `br-ext` will ever need a path to `10.10.0.100`: MariaDB and the
  internal endpoints stay on `br-mgmt` only, whatever rule P4 opens.
* Good, because every API call, between services too, is HTTPS, checked against the lab's
  root.
* Good, because the key follows the passwords' path: OpenBao, then the bastion's tmpfs for a
  run. The design and its checks already exist (ADR-0052).
* Good, because it is Kolla's standard flow: Kolla copies the files and restarts HAProxy
  when they change.
* Bad, because the key also lives on `os-ctl01`'s disk (`/etc/kolla/haproxy/`), where HAProxy
  reads it. Every option has this.
* Bad, because one certificate serves both VIPs: its key opens both. They are on the same VM
  anyway.
* Bad, because the operator can read the key; root on the bastion during a run could copy it,
  as it could the passwords (ADR-0052).
* Bad, because renewal is by hand once a year. The helper's warning and refusal make a
  forgotten renewal visible at the next Kolla run, not when clients fail.
* Neutral: one more address on `br-mgmt`, and one more frontend per API in HAProxy, with
  memory use near zero (INFERRED; measured with the rest in step 6).

### Confirmation

Step 4c, before any deployment:
* the router answers for both names, forward and reverse;
* the operator can read `kv/kolla/tls/haproxy` and can neither write it nor issue a
  certificate;
* `read` writes the three files on the tmpfs, and its checks pass. With a certificate that
  expires soon, or one of the wrong names, the checks fail (tested in a container);
* `clean` leaves the tmpfs empty.

Step 5, after the deployment:
* `openstack endpoint list` shows `https://api-int.akasha.internal:…` for the internal
  endpoints and `https://api.akasha.internal:…` for the public ones;
* `curl --cacert infra/pki/akasha-root-ca.crt` succeeds on both VIPs, and fails without
  `--cacert`;
* nothing listens on `10.10.0.101:3306`.

## More Information

* Kolla-Ansible 2026.1, TLS: https://docs.openstack.org/kolla-ansible/2026.1/admin/tls.html
* The pinned commit's source: `ansible/group_vars/all/common.yml` (VIPs, FQDNs,
  `kolla_same_external_internal_vip`), `ansible/group_vars/all/haproxy.yml`,
  `ansible/roles/loadbalancer/tasks/copy-certs.yml`, `ansible/roles/service-cert-copy/`,
  `ansible/roles/letsencrypt/`.
* StackHPC, OpenBao for internal PKI with Kayobe:
  https://stackhpc-kayobe-config.readthedocs.io/en/stackhpc-2025.1/configuration/openbao.html
* Related: ADR-0006 (V1b topology), ADR-0037 (router), ADR-0044 (root CA), ADR-0046 (PKI role
  `server`), ADR-0047 (trust), ADR-0052 (tmpfs and helper).
