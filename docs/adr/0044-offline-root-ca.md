---
status: accepted
date: 2026-11-25
decision-makers: dhuy21
---

# The lab's offline root CA

## Context and Problem Statement

[ADR-0019](0019-certificate-management.md) keeps a root CA offline. The root signs only an
intermediate CA held by OpenBao (step 7d), and that intermediate issues every certificate of
the lab. Nothing said yet how the root is made, what it may sign, or where its key lives.
The owner's laptop will trust this root, so a misused intermediate must not be able to
impersonate sites outside the lab.

Facts checked on 2026-11-25:

* **Name constraints** of a root are applied to every certificate below it:
  * by Go's `crypto/x509` (`isValid` checks the constraints of an intermediate or root
    certificate, verify.go in Go 1.25);
  * by OpenSSL (`check_name_constraints` in `x509_vfy.c` applies the constraints of every
    certificate above, the trust anchor included).

  kubectl, Argo CD, OpenTofu, curl and Python verify with one of these two libraries.
  Browsers were not checked (INFERRED).
* **age 1.3.2**, published 2026-08-29, is in mise's registry (`aqua:FiloSottile/age`), with
  GitHub attestations.
* **The laptop** (measured): its disk is not encrypted, and its swap is a file on that disk.

## Decision Drivers

* The root key never lies on a disk in clear text, and never on a networked server.
* A misused intermediate can only name the lab.
* Losing the laptop must not end the PKI. The owner keeps secrets in files on the laptop only,
  with no password manager.

## Considered Options

* **Algorithm:** ECDSA P-384, or RSA 4096.
* **Validity:** 5, 10 or 20 years.
* **Name constraints:**
  * `akasha.internal`, `10.0.0.0/8` and `cluster.local`;
  * the same without `cluster.local`;
  * none.
* **Tool:** OpenSSL with age, or smallstep's `step` with age.
* **Swap during the ceremony:**
  * turn it off;
  * accept the risk;
  * a live USB system with no disk.

## Decision Outcome

Chosen by the owner on 2026-11-25:

* **The root.**
  * ECDSA P-384, SHA-384, valid for **10 years**.
  * Subject `O=akasha, CN=akasha Root CA`.
  * Configuration in [`infra/pki/root-ca.cnf`](../../infra/pki/root-ca.cnf):
    * `basicConstraints` critical, `CA:true`, `pathlen:1`. One CA level below: OpenBao's
      intermediate.
    * `keyUsage` critical, `keyCertSign` and `cRLSign`.
    * `nameConstraints` critical. Permitted: DNS `akasha.internal` and `cluster.local`
      (each with its subdomains), and IP `10.0.0.0/8`. These cover the lab's names, every
      10.x range (lab, OpenStack tenants, pods and services) and Kubernetes' internal names.
* **The ceremony**, on the laptop, run by the owner (runbook
  [pki-root-ca.md](../runbooks/pki-root-ca.md)):
  * Swap is turned off first.
  * `openssl genpkey` writes the key into a pipe to `age -p`. The key exists in clear text
    only in memory.
  * `age -d` writes the key into a pipe to `openssl req -x509`. The same pipe is used later
    to sign the intermediate.
* **The files.**
  * `~/akasha-private/pki/root-ca.key.age`, encrypted with a passphrase. The owner remembers
    the passphrase, and a handwritten copy is kept away from the laptop. How the unseal shares
    are encrypted is decided in step 7c-2.
  * The certificate is public and committed: `infra/pki/akasha-root-ca.crt`.
* **Off the laptop.** Step 7e (restic to S3, open question A13) backs up `~/akasha-private`,
  encrypted. Until then the only copy is on the laptop. That risk is accepted, because nothing
  depends on the root yet.
* **age** joins the pinned toolchain (ADR-0022).

### Consequences

* Good, because the root key exists only encrypted at rest.
* Good, because a certificate for a name outside the lab fails verification, even when the
  intermediate signs it.
* Good, because OpenSSL and age are small, auditable tools; the configuration is a reviewed
  file.
* Bad, because a name outside these constraints (another domain, a non-10.x address, an
  e-mail or URI constraint) needs a new root, distributed again to every client.
* Bad, because until step 7e a lost laptop loses the root key. Then the PKI is rebuilt from
  zero.
* Bad, because the laptop's disk is not encrypted. Only the age file protects the key, so the
  passphrase is its only defence.
* Bad, because the root is not revocable in practice: if its key leaks, every client must
  remove it by hand.

### Confirmation

* Rehearsed first with a throwaway key and an age identity:
  * leaf certificates for `test.akasha.internal`, `web.default.svc.cluster.local` and
    `10.10.0.12` verified `OK` through a throwaway intermediate;
  * `example.com`, `192.168.1.1` and `akasha.internal.evil.com` failed with "permitted
    subtree violation".
* The real root, made on 2026-11-25:
  * it verifies as self-signed, with the extensions above and a P-384 key;
  * SHA-256 fingerprint
    `61:C1:73:BA:8C:32:AE:63:0A:BC:08:06:88:55:E2:7B:26:65:C1:D6:7D:D8:94:FE:4A:79:64:F1:24:9F:0A:C6`;
  * the key decrypted with the passphrase read from the paper copy, and its public key equals
    the certificate's.

## More Information

* Go: https://github.com/golang/go/blob/go1.25.0/src/crypto/x509/verify.go.
* OpenSSL: https://github.com/openssl/openssl/blob/openssl-3.5.0/crypto/x509/x509_vfy.c.
* age: https://github.com/FiloSottile/age.
* RFC 5280 §4.2.1.10 (name constraints).
