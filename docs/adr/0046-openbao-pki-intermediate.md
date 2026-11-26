---
status: accepted
date: 2026-11-26
decision-makers: dhuy21
---

# OpenBao's intermediate CA, configured with OpenTofu

## Context and Problem Statement

Step 7d gives the lab a certificate authority that can issue certificates. The offline root
of [ADR-0044](0044-offline-root-ca.md) signs an intermediate CA held by OpenBao
([ADR-0019](0019-certificate-management.md)). OpenBao was initialised in step 7c-2
([ADR-0045](0045-openbao-initialisation-and-administration.md)). It listens on loopback only
until step 7d-2 adds TLS. Several points were open:
* how OpenBao's configuration is kept as code;
* where that code's state lives, and how it reaches OpenBao;
* the intermediate's parameters, and what it may issue.

The owner split step 7d on 2026-11-26:
* 7d-1, this ADR: the intermediate and its role, with no change to OpenBao's network side;
* 7d-2: OpenBao's own TLS certificate and listener, port 8200, the trust stores, and the
  admin's address binding.

Facts checked on 2026-11-26:
* **No OpenBao provider exists yet.** OpenBao's RFC "Dedicated OpenBao OpenTofu/Terraform
  Provider" (`website/content/community/rfcs/dedicated-tf-provider.mdx`, main branch) says the
  Vault provider "still works for most tasks", with growing friction.
* **`hashicorp/vault`**, MPL-2.0, is on the OpenTofu registry, signed by HashiCorp.
  * 5.13.0 was published on 2026-10-14, outside the cooldown.
  * 5.14.0 was published on 2026-11-24, inside it.
* **`allowed_ip_sans_cidr`** limits the IP addresses a role may issue for. It is an OpenBao
  role field (`internal/builtin/logical/pki/path_roles.go` at v2.7.3) that the provider's
  `vault_pki_secret_backend_role` does not have (`resource_pki_secret_backend_role.go`,
  v5.13.0).
* **IAM.** The policy of `akasha-l0` allows only the key `l0/terraform.tfstate` and its lock
  (runbook `aws-l0-state.md`).
* **Tested** in a Debian 13 container with OpenBao 2.7.3 and the provider 5.13.0:
  * the first apply created the mount, the URLs, the role and an internal P-384 CSR;
  * the CSR was signed by a throwaway root with the root's name constraints, as the runbook
    signs it;
  * the second apply imported the certificate and the root. The intermediate, which holds the
    key, became the default issuer;
  * a certificate for `core.akasha.internal` with `10.10.0.12` verified against the root;
  * `example.com`, `192.168.1.1` and `localhost` were refused by the role;
  * a TTL above one year was cut to one year;
  * a second plan showed no changes, once the role's TTLs were written in seconds.

## Decision Drivers

* Configuration as code, reviewed in pull requests, with drift visible in a plan.
* The intermediate's key never leaves OpenBao; the root's key never leaves the laptop.
* No change to OpenBao's network exposure in this step.
* A certificate for a name outside the lab is refused at issuance, not only at verification.

## Considered Options

* **Configuration as code:** a bash script; **OpenTofu with the Vault provider**; Ansible's
  `community.hashi_vault`.
* **State:** **the L0 bucket under its own key**; a local file; a new bucket and user.
* **Passphrase:** **its own (`openbao`)**; the L0 one.
* **Path to OpenBao:** **an SSH tunnel to the loopback listener, always**; a tunnel first, then
  TLS.
* **Intermediate:** **P-384, 5 years, pathlen 0**; P-384, 3 years; P-256, 5 years.
* **Roles:** **one `server` role, ACME later**; `server` and ACME now.

## Decision Outcome

Chosen by the owner on 2026-11-26 (the options in bold).

* **The stack `infra/opentofu/live/openbao/`**:
  * `hashicorp/vault` pinned to `= 5.13.0`;
  * applied by the owner only, from the laptop, like L0;
  * state in the L0 bucket under `openbao/terraform.tfstate`, with `use_lockfile`. The policy
    `akasha-l0-state` of `akasha-l0` gets the new key and its lock;
  * state and plans encrypted with `pbkdf2`, from the keyring passphrase `openbao` (paper
    copy);
  * provider address fixed to `http://127.0.0.1:8200`, reached only through
    `ssh -L 127.0.0.1:8200:127.0.0.1:8200 debian@10.10.0.12`;
  * the admin's token in `VAULT_TOKEN`, from a userpass login piped from the age-encrypted
    password. It is revoked at the end of the session.
* **The PKI**, mount `pki`:
  * mount TTL 30 days by default, **1 year at most**;
  * intermediate `O=akasha, CN=akasha Intermediate CA`:
    * an EC P-384 key, generated inside OpenBao (`type = "internal"`, `key_name =
      intermediate-2026`);
    * signed on the laptop by the offline root with `infra/pki/intermediate-ca.ext`:
      `CA:true`, `pathlen:0`, `keyCertSign`, `cRLSign`;
    * **5 years** (1826 days), SHA-384;
  * the signed certificate and the root imported as the chain; the intermediate is the
    default issuer;
  * the CSR and the signed certificate are public and committed in `infra/pki/`;
  * URLs: `https://core.akasha.internal:8200/v1/pki/ca` and `…/crl`, live from step 7d-2;
  * `prevent_destroy` on the mount and on the CSR, because destroying or replacing either
    deletes the intermediate's key.
* **The role `server`**, written through `vault_generic_endpoint` so that OpenBao's
  `allowed_ip_sans_cidr` can be set:
  * subdomains of `akasha.internal` only, no wildcard, no bare domain, no `localhost`;
  * IP SANs in `10.0.0.0/8` only;
  * server authentication only;
  * EC P-256 keys;
  * 30 days by default, 1 year at most.
* **ACME** and a `cluster.local` role wait until they have users: Kolla in P2, cert-manager in
  P5.

### Consequences

* Good, because OpenBao's PKI configuration is code, planned and reviewed like the rest.
* Good, because OpenBao refuses a name or address outside the lab, before the root's name
  constraints would make the certificate fail anyway.
* Good, because neither CA key leaves its home: OpenBao for the intermediate, the laptop's
  age file for the root.
* Bad, because the Vault provider is not made for OpenBao. Each new OpenBao feature may need
  `vault_generic_endpoint`, and each provider upgrade must be tested against OpenBao. A
  dedicated provider would replace it (OpenBao RFC); the RFC plans a `state
  replace-provider` migration.
* Bad, because the admin's token sits in the laptop shell's environment for the session.
* Bad, because one more passphrase is kept, in the keyring and on paper.
* Bad, because the intermediate expires in 5 years. Replacing it is a new CSR, a new root
  signature and an import, before the expiry.

### Confirmation

The container test above, then on `core`:
* both applies succeed, and a third plan shows no changes;
* the default issuer is the intermediate;
* a one-hour test certificate verifies against `infra/pki/akasha-root-ca.crt`, and is then
  revoked;
* `example.com` is refused;
* the state object in S3 is encrypted, and an off-AWS copy is taken.

## More Information

* Runbook: [openbao-pki.md](../runbooks/openbao-pki.md).
* Vault provider: https://github.com/hashicorp/terraform-provider-vault (v5.13.0);
  OpenBao PKI API: `website/content/docs/api/secret/pki/index.mdx` (v2.7.3).
* ADR-0007 (OpenTofu), ADR-0022 (cooldown), ADR-0031 (L0 bucket), ADR-0044, ADR-0045.
