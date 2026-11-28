---
status: accepted
date: 2026-11-28
decision-makers: dhuy21
---

# Kolla's passwords in OpenBao KV v2, on the bastion only in RAM during a run

## Context and Problem Statement

Kolla-Ansible keeps every secret of the cloud in `passwords.yml`: about 120 values that
`kolla-genpwd` generates. Among them:
* the Keystone admin, MariaDB and RabbitMQ passwords;
* Nova's SSH key pair;
* encryption keys.

Whoever reads the file controls OpenStack. ADR-0011 put these passwords in OpenBao's KV v2,
materialised on tmpfs only for a run. Open question A5 asks whether Kolla's tools work against
OpenBao: they were written for HashiCorp Vault.

Every `kolla-ansible` command reads `<configdir>/passwords.yml`. `--passwords` does not change
that path (ADR-0051 Implementation).

Facts checked on 2026-11-28, in kolla-ansible at the pinned commit `d9658dc` (ADR-0051):
* **`kolla-writepwd`** (`kolla_ansible/cmd/writepwd.py`).
  * It stores each password as its own secret, `<mount>/<path>/<name>`, as
    `{"password": "…"}`; a structured value (an SSH key pair) is stored as it is.
  * It writes only values that changed, skips empty ones and never deletes.
* **`kolla-readpwd`** (`cmd/readpwd.py`).
  * It needs a template, a `passwords.yml` whose keys it reads one by one. A key missing in
    OpenBao becomes empty, with a warning.
  * It writes the file again with mode 0640.
* **Authentication** (`hashi_vault.py`, through `hvac`).
  * A token, or an AppRole's role ID and secret ID, is passed **on the command line**, where
    other users of the machine see it (`ps`).
  * `--vault-cacert` sets `REQUESTS_CA_BUNDLE`. Without it, `requests` does not use the
    system's trust store, which holds the lab's root CA (ADR-0047).
* **OpenBao.** Upstream's CI runs `kolla-writepwd` and `kolla-readpwd` against OpenBao 2.4.1
  in dev mode, on its KV v2 mount `secret` (`tests/test-openbao-passwords.sh`). The lab runs
  2.7.3: INFERRED to work, tested in a container before the lab.
* **Upgrades.** New passwords of a new Kolla release are added with `kolla-genpwd` and
  `kolla-mergepwd`, then written back (`doc/source/user/operating-kolla.rst`).
* **KV v2** keeps 10 versions of each secret by default, so a value written by mistake can be
  read back. OpenBao's daily snapshot (ADR-0049) carries the passwords off-site.
* **tmpfs and swap.** A tmpfs page can be swapped out, and the bastion has a 1 GiB swap file on
  its disk (ADR-0030). tmpfs has a `noswap` option since Linux 6.4 (kernel documentation,
  `filesystems/tmpfs.rst`); Debian 13 runs Linux 6.12.

## Decision Drivers

* The passwords never reach a disk, a command line, a log or git.
* No initialisation may ever overwrite the passwords of a running cloud.
* One identity for the owner on the bastion, as for SSH (ADR-0050).
* A forgotten copy disappears on its own.

## Considered Options

* **Who writes:**
  * **the operator, who may read and write but not delete**;
  * the operator reads, and the admin writes through the laptop's tunnel.
* **Where the copy lives during a run:**
  * **a tmpfs of its own, without swap**;
  * `/dev/shm`.
* **When the copy goes:**
  * **by hand, and a timer removes any copy older than 8 hours**;
  * by hand only.
* **SSH certificate and passwords:**
  * **two commands**;
  * one command for both.

## Decision Outcome

Chosen by the owner on 2026-11-28 (the options in bold).

* **OpenBao** (stack `openbao`):
  * a KV v2 mount `kv`. The passwords live at `kv/kolla/passwords/<name>`, the path that
    `kolla-writepwd` builds from its arguments;
  * the policy `operator` also gets, on those secrets:
    * read, create and update;
    * the listing of their names.

    It gets no delete, undelete, destroy or metadata change;
  * nothing else changes: the operator's tokens stay 15-minute tokens bound to `10.10.0.10`
    (ADR-0050).
* **The bastion:**
  * **A tmpfs at `/run/akasha-kolla`:**
    * options `noswap`, `size=1m`, `mode=0700`, owner `akasha`, `nosuid`, `nodev`, `noexec`;
    * mounted at boot, and empty after every boot;
    * `infra/kolla/passwords.yml` is a symbolic link to `/run/akasha-kolla/passwords.yml`
      (the name is git-ignored).
  * **`akasha-kolla-passwords`**, run as `akasha`, with the operator's password on stdin from
    the laptop, like `akasha-ssh-cert`:
    * it logs in and revokes its token at the end;
    * it calls Kolla's `readpwd()` and `writepwd()` in Python, with the token in the
      environment, never on a command line, and the system's CA bundle;
    * modes:
      * `read`: fill a copy of the installed Kolla's template; fail if any value is missing;
        link it;
      * `init` (once): refuse if `kv/kolla/passwords` lists anything; generate on the tmpfs
        with `kolla-genpwd`; write; read back and compare; remove the copy;
      * `clean`: remove the copy and the link.
  * **A root timer** removes any copy older than 8 hours, the lifetime of an SSH certificate.
* **Merging new passwords at an upgrade** (`kolla-mergepwd`) is added with the first bump that
  needs it.

### Consequences

* Good, because the passwords exist only in OpenBao and its backups, and in RAM on the bastion
  while Kolla runs. They never reach the bastion's swap or disk, or a command line.
* Good, because an `init` cannot overwrite existing passwords. A wrong write is undone from the
  KV versions.
* Good, because the daily snapshot already backs them up off-site.
* Bad, because the operator's password now also opens every password of the cloud. Its reach
  is still limited to the bastion's address and 15-minute tokens, and the response to a
  stolen bastion (runbook `bastion.md`) gains a step: change the cloud's passwords.
* Bad, because no deployment can start while OpenBao is sealed (as for SSH certificates).
* Bad, because one more helper and one more mount must be kept in step with Kolla: a new
  template at a bump, and `kolla-mergepwd` when a release adds passwords.
* Neutral: KV v2 keeps the old values of a changed password for 10 versions, readable by the
  operator.

### Confirmation

In a container, with OpenBao 2.7.3 configured like the lab:
* `init` writes every non-empty value, `read` gives back the same file, and a second `init`
  refuses;
* the operator cannot delete or destroy a secret;
* the token never appears in the process list.

On the lab:
* the plan of stack `openbao` adds the mount and changes the policy only;
* the bastion's role runs twice, the second time with `changed=0`, and
  `findmnt /run/akasha-kolla` shows `noswap`;
* `init` once, then `read` gives the same values without printing them;
* `kolla-ansible gather-facts` runs with the passwords, then `clean` leaves nothing.

Open question A5 is then answered.

## More Information

* Kolla-Ansible 2026.1, "Operating Kolla", section on passwords:
  https://docs.openstack.org/kolla-ansible/2026.1/user/operating-kolla.html
* Source at the pinned commit: `kolla_ansible/cmd/readpwd.py`, `writepwd.py`,
  `hashi_vault.py`, `tests/test-openbao-passwords.sh`.
* OpenBao, "KV secrets engine - version 2": https://openbao.org/docs/secrets/kv/kv-v2/
* Linux 6.12, `Documentation/filesystems/tmpfs.rst` (`noswap`).
* ADR-0011 (OpenBao), ADR-0030 (swap), ADR-0047 (the lab's CA), ADR-0049 (OpenBao's backups),
  ADR-0050 (the operator), ADR-0051 (Kolla's toolchain).
