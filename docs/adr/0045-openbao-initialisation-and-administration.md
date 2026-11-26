---
status: accepted
date: 2026-11-26
decision-makers: dhuy21
---

# OpenBao: initialisation, unseal shares, audit log and administrator

## Context and Problem Statement

Step 7c-2 initialises OpenBao on `core`. ADR-0011 chose a Shamir seal, unsealed by hand.
ADR-0039 keeps OpenBao on localhost without TLS until step 7d, with the initialisation over
SSH. Self-initialisation cannot be used with Shamir (ADR-0011 Updates). Still to decide:
* how the shares and the root token reach the laptop and are kept;
* how OpenBao is unsealed after each reboot;
* where the audit log goes;
* who administers OpenBao once the root token is revoked.

Facts checked on 2026-11-26 in OpenBao 2.7.3:
* **Init.** `bao operator init -format=json` prints the shares and the root token as JSON. It
  runs without a terminal, so its output can go through a pipe.
* **Unseal.** `bao operator unseal` reads a share only from a terminal or from its command
  line, and other processes can read a command line. The API `PUT /v1/sys/unseal` takes the
  share in the request body.
* **Audit.** Source: the audit documentation.
  * Since 2.3.2, an audit device cannot be created through the API without
    `unsafe_allow_api_audit_creation`. It is declared in the configuration instead.
  * OpenBao answers no request that no audit device can record.
  * SIGHUP makes a `file` device reopen its file. The package's unit sends SIGHUP on
    `systemctl reload`.
* **The role** never restarts an initialised OpenBao (ADR-0039). A configuration change made
  after the initialisation needs a restart and an unseal by hand.
* **age** decrypts a passphrase-protected identity file given to `-i` (age 1.3.2 README).

Tested in a Debian 13 container with the pinned package and the files of this ADR:
* init through a pipe straight into age;
* the three shares split into separate files;
* unsealed with shares 1 and 2, then sealed by the admin and unsealed with shares 3 and 1;
* the bootstrap:
  * it refused a line that was not a root token;
  * it created the admin;
  * the root token was revoked, and a second run refused that token;
* the audit device was enabled at unseal (file mode 0600), and passwords were HMAC'd in it;
* a forced logrotate made OpenBao reopen the file, and it stayed unsealed.

After the independent review, the ceremony was run again over real SSH, against a container
with sshd, `/etc/openbao` at `root:openbao 0750` and the user `debian`, as on `core`. Two
blockers found by the review were confirmed there and fixed:
* a policy file under `/etc/openbao` cannot be read by `debian`;
* Debian's sshd gives non-root users a `PATH` without `sbin` directories.

## Decision Drivers

* No share, root token or password appears on a screen, on a command line, in a clipboard, or
  in clear text on a disk.
* The Shamir split must be usable later: one share can be moved elsewhere without re-keying.
* Nothing runs with a root token after the first setup.
* Every request is audited, and the log survives a rebuild of `core` (ADR-0038).

## Considered Options

* **Shares:**
  * three files encrypted to one age identity, itself protected by a passphrase;
  * three files, each encrypted with the passphrase directly;
  * one file holding all three.
* **Administration:**
  * a userpass user `admin` with an `admin` policy;
  * a long-lived admin token;
  * none: a new root token from `bao operator generate-root` each time.
* **Audit:**
  * a file on the data disk, rotated by logrotate;
  * a file plus syslog;
  * syslog only.
* **Passphrase:** the root CA's (ADR-0044), or a new one.

## Decision Outcome

Chosen by the owner on 2026-11-26: the age identity, userpass, a file on the data disk, and
the same passphrase.

* **The files on the laptop**, in `~/akasha-private/openbao/`, created with `umask 077`:

  | File | Content | Encryption |
  |---|---|---|
  | `identity.age` | the age identity | `age -p`, the passphrase of ADR-0044 |
  | `recipient.txt` | its public key | none (public) |
  | `share-1.age`, `share-2.age`, `share-3.age` | one share each | to the recipient |
  | `admin-password.age` | the admin's password, 32 random bytes | to the recipient |

  Encrypting needs only the public key. Each decryption asks for the passphrase once.
* **The initialisation** (runbook `core.md`):
  * `ssh core 'bao operator init -key-shares=3 -key-threshold=2 -format=json'` writes straight
    into `age -R recipient.txt`, so the JSON exists in clear only in pipes.
  * The shares are split from it into the three files. The JSON file is shredded once the
    root token is revoked and every share has unsealed OpenBao.
  * Swap is off on the laptop during the ceremony, as for the root CA.
* **Guards.** Every command of the ceremony checks its inputs first and refuses to overwrite
  an existing file, because `age -o` overwrites without asking. Every secret file is made
  read-only (`chmod 400`) as soon as it is written. SSH runs with `BatchMode=yes`, so that
  only age prompts on the terminal.
* **Unseal**, after each reboot of `core`: `age -d -i identity.age share-N.age | ssh core
  akasha-bao-unseal`, for two shares. `akasha-bao-unseal` is a small Python script installed
  by the role in `/usr/local/bin`, which is on the PATH of a non-interactive SSH session. It
  reads one share from stdin and calls `PUT /v1/sys/unseal`.
* **Audit.** The role declares `audit "file"` in `openbao.hcl`, writing
  `/srv/openbao/audit/audit.log` (mode 0600, directory 950:950 0700). It is declared before
  the initialisation, while the role may still restart OpenBao. logrotate keeps 30 days,
  compressed, and reloads OpenBao after each rotation.
* **Administrator.** `akasha-bao-bootstrap`, installed by the role, runs once with the root
  token and the admin password on stdin. It:
  * writes the `admin` policy, held in the script: every path, with `sudo`;
  * enables `userpass` and creates the user `admin`, with tokens of 1 h (4 h at most);
  * logs in as `admin` to prove the policy, then revokes that login's token;
  * revokes the root token, and checks that it no longer works.

  A new root token, if ever needed, comes from `bao operator generate-root` with two shares.

### Consequences

* Good, because no secret of the initialisation ever shows on a screen or lands in clear on a
  disk.
* Good, because one share can be moved to another place later by copying one file.
* Good, because every request is audited on the data disk, and a full disk stops OpenBao
  rather than leaving requests unaudited (fail-closed).
* Good, because the admin's tokens expire and are audited under a name, unlike a root token.
* Bad, because the `admin` policy can do everything a root token can, except outlive its 1 h
  TTL. It is a convenience, not a separation of duties.
* Bad, because the shares, the admin password and the identity all sit on the laptop, behind
  one passphrase, until step 7e copies them off the laptop. Lose the laptop and the paper
  copy, and OpenBao's data is lost for good.
* Bad, because a configuration the role writes on an initialised OpenBao is not applied at
  once: the role stops and asks for a restart and an unseal. Meanwhile, SIGHUP also reloads
  the declarative audit stanza, so logrotate's next daily reload would apply an audit change
  without that restart. The runbook therefore asks for the restart on the same day.
* Bad, because the identity and the shares pass through the laptop's memory at every unseal,
  with swap on (INFERRED: a tiny risk on its unencrypted disk).
* Bad, because the admin's token is stored on `core` in `~/.vault-token` after a login. It
  lives at most 4 h; the runbook revokes it when the work is done.
* Note for step 7d: once the listener is on the network, the admin password alone would log
  in from any address. `token_bound_cidrs` on the user is to be decided then.

### Confirmation

On `core`, after the ceremony:
* the role's checks pass, including the audit directory, and the audit file once unsealed;
  a second run reports `changed=0`;
* `bao status`: initialised, unsealed, 3 shares, threshold 2;
* the admin logs in and holds `admin` and `default`, with a TTL of about 1 h, and is the only
  live token;
* the root token is refused;
* the admin seals OpenBao, and shares 3 and 1 unseal it, so every share works;
* the audit log holds lines, owned by `openbao`, mode 0600.

### Implementation (2026-11-26)

Run on `core` from PR #78, with the laptop's swap off.
* **Role.**
  * The first run made 6 changes, then restarted the still uninitialised OpenBao: the audit
    directory (950:950 0700), the audit stanza, the two helpers, logrotate and its
    configuration.
  * The second run reported `changed=0`. So did a run after the initialisation, with every
    check passing.
* **Laptop files.**
  * The identity decrypted with the passphrase read from the paper copy, and matched
    `recipient.txt`.
  * After the init, the JSON held 3 shares, threshold 2, and a root token.
  * Every file is `-r--------`. `init.json.age` was shredded at the end, on the owner's
    confirmation.
* **OpenBao.**
  * Initialised, unsealed with shares 1 and 2: 3 shares, threshold 2, HA mode active.
  * The audit file was created at unseal, `openbao` 0600.
  * The bootstrap created the admin and revoked its test login and the root token. The root
    token was then refused when tried independently.
* **Admin.**
  * `userpass-admin`, policies `admin` and `default`, TTL 1 h, the only live token.
  * It sealed OpenBao, and shares 3 and 1 unsealed it, so all three shares work.
* **A puzzling 403, explained by the audit log.** A `revoke-self` returned "permission
  denied". The audit log showed that the same command had already run once: it revoked the
  admin's token and deleted `~/.vault-token`. The second run then sent no token. Tokens
  survive a seal and an unseal, as the source says (`sealInitCommon` revokes only a token at
  its last use).
* **Audit.** 19 requests, each with its response, after the ceremony. The only denials were the two
  expected root-token tries and that token-less `revoke-self`.

## More Information

* OpenBao documentation (v2.7.3 sources): audit devices and blocked devices
  (`website/content/docs/audit/index.mdx`, `file.mdx`), declarative audit
  (`docs/configuration/audit.mdx`); `internal/command/operator_unseal.go`.
* age: https://github.com/FiloSottile/age (passphrase-protected key files).
* ADR-0011, ADR-0038, ADR-0039, ADR-0044.
