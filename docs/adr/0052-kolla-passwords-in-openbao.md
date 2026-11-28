---
status: accepted
date: 2026-11-28
decision-makers: dhuy21
---

# Kolla's passwords in OpenBao KV v2, on the bastion only in RAM during a run

## Context and Problem Statement

Kolla-Ansible keeps every secret of the cloud in `passwords.yml`: 107 values that
`kolla-genpwd` generates. Among them:
* the Keystone admin, MariaDB and RabbitMQ passwords;
* Nova's SSH key pair;
* encryption keys.

Whoever reads the file controls OpenStack. ADR-0011 put these passwords in OpenBao's KV v2,
materialised on tmpfs only for a run. Open question A5 asks whether Kolla's tools work against
OpenBao: they were written for HashiCorp Vault.

Every `kolla-ansible` command reads `<configdir>/passwords.yml`. `--passwords` does not change
that path (ADR-0051 Implementation).

Facts checked on 2026-11-28, in kolla-ansible at the pinned commit `d9658dc` (ADR-0051) and in
ansible-core 2.20.10:
* **`kolla-writepwd`** (`kolla_ansible/cmd/writepwd.py`).
  * It stores each password as its own secret, `<mount>/<path>/<name>`, as
    `{"password": "…"}`; a structured value (an SSH key pair) is stored as it is.
  * It writes only values that changed, skips empty ones and never deletes.
* **`kolla-readpwd`** (`cmd/readpwd.py`).
  * It needs a template, a `passwords.yml` whose keys it reads one by one. A key missing in
    OpenBao becomes empty, with a warning.
  * It writes the file again with mode 0640.
* **`kolla-genpwd`** leaves one key empty on purpose, `docker_registry_password` (`blank_keys`
  in `cmd/genpwd.py`).
* **Authentication** (`hashi_vault.py`, through `hvac`).
  * A token, or an AppRole's role ID and secret ID, is passed **on the command line**, where
    other users of the machine see it (`ps`).
  * `--vault-cacert` sets `REQUESTS_CA_BUNDLE`. Without it, `requests` does not use the
    system's trust store, which holds the lab's root CA (ADR-0047).
* **OpenBao.** Upstream's CI runs `kolla-writepwd` and `kolla-readpwd` against OpenBao 2.4.1
  in dev mode, on its KV v2 mount `secret` (`tests/test-openbao-passwords.sh`).
* **Upgrades.** New passwords of a new Kolla release are added with `kolla-genpwd` and
  `kolla-mergepwd`, then written back (`doc/source/user/operating-kolla.rst`).
* **KV v2.**
  * It keeps 10 versions of each secret by default. Whoever may update a secret can therefore
    push its original value out with 10 writes (verified on OpenBao 2.7.3 by the independent
    review).
  * It tells apart writing a new secret (capability `create`) from changing one that exists
    (`update`).
  * OpenBao's daily snapshot (ADR-0049) carries the passwords off-site.
* **Ansible's temporary files.** During a run, Ansible renders configuration files, which
  hold passwords, into its local temporary directory before copying them to the nodes:
  * ansible-core's `template` and `copy` actions;
  * Kolla's `merge_configs` and `merge_yaml`.

  That directory is `~/.ansible/tmp` by default, on the bastion's disk. Tasks run on the
  deployment host itself use its remote temporary directory, also `~/.ansible/tmp`.
* **`kolla-ansible post-deploy`** writes `clouds.yaml` and `*openrc*.sh`, with the Keystone
  admin password, into the configuration directory (`ansible/post-deploy.yml`,
  `node_config` = `CONFIG_DIR`).
* **tmpfs and swap.** A tmpfs page can be swapped out, and the bastion has a 1 GiB swap file on
  its disk (ADR-0030). tmpfs has a `noswap` option since Linux 6.4 (kernel documentation,
  `filesystems/tmpfs.rst`); Debian 13 runs Linux 6.12. `noswap` covers the files on that
  tmpfs only, not the memory of the processes that read them.

## Decision Drivers

* The passwords never reach a file on a disk, a command line, a log or git.
* No initialisation may ever overwrite the passwords of a running cloud, and the bastion may
  never change or destroy an existing one.
* One identity for the owner on the bastion, as for SSH (ADR-0050).
* A forgotten copy disappears on its own.

## Considered Options

* **What the operator may do on the passwords:**
  * **read, and create new ones only**;
  * read and write (create and update), without delete. The owner chose it first; the
    independent review then showed that 10 updates push a value out of KV v2.
* **Where the copy and Ansible's temporary files live during a run:**
  * **a tmpfs of its own, without swap**;
  * `/dev/shm`.
* **The memory of the running processes**, which can still be swapped to the disk:
  * **accept, and say so**;
  * an encrypted swap with a key that changes at each boot;
  * zram instead of the swap file.
* **When the copy goes:**
  * **by hand, and a timer removes any copy older than 8 hours**;
  * by hand only.
* **SSH certificate and passwords:**
  * **two commands**;
  * one command for both.

## Decision Outcome

Chosen by the owner on 2026-11-28 (the options in bold).

* **OpenBao** (stack `openbao`, `kv.tf`):
  * a KV v2 mount `kv`, with `prevent_destroy`. The passwords live at
    `kv/kolla/passwords/<name>`;
  * a policy `kolla-passwords`, which the userpass user `operator` gets next to its policy
    `operator` (`ssh.tf`). On those secrets, it allows:
    * `read` and `create`;
    * the listing of their names.

    It allows no `update`, delete, undelete, destroy or metadata change. Changing an existing
    password is the admin's, through the laptop's tunnel;
  * nothing else changes: the operator's tokens stay 15-minute tokens bound to `10.10.0.10`
    (ADR-0050).
* **The bastion** (role `bastion_kolla_passwords`, tag `kolla_passwords`):
  * **A tmpfs at `/run/akasha-kolla`:**
    * options `noswap`, `size=32m` (a ceiling, not a reservation), `mode=0700`, owner
      `akasha`, `nosuid`, `nodev`, `noexec`;
    * declared in `/etc/fstab`, and empty after every boot.
  * **What lives on it:**
    * the copy `passwords.yml`;
    * Ansible's local temporary directory for Kolla, through `local_tmp` in
      `infra/kolla/ansible.cfg`. Without the tmpfs, Ansible cannot create it and stops;
    * the deployment host's remote temporary directory (`ansible_remote_tmp` in
      `multinode`).

    `infra/kolla/passwords.yml` is a symbolic link to the copy.
  * **`akasha-kolla-passwords`**, run as `akasha`, with the operator's password on stdin from
    the laptop, like `akasha-ssh-cert`:
    * it logs in and revokes its token at the end;
    * it calls Kolla's `readpwd()` and `writepwd()` in Python, with the token in the
      environment, never on a command line, and the system's CA bundle;
    * it disables core dumps;
    * modes:
      * `read`: first remove any older copy and its link; fill a copy of the installed Kolla's
        template; fail if any value but the blank one is missing; link it;
      * `init` (once): refuse if `kv/kolla/passwords` lists anything; generate on the tmpfs
        with `kolla-genpwd`; check that nothing but the blank key is empty; write; read back
        and compare; remove the copy;
      * `clean`: empty the tmpfs; remove the link and the files of `post-deploy`.
  * **A root timer** removes any file on the tmpfs older than 8 hours, the lifetime of an SSH
    certificate.
* **The repository:** `.gitignore` covers `infra/kolla/clouds.yaml` and
  `infra/kolla/*openrc*.sh`. Where `post-deploy`'s credentials live is decided with the
  deployment (P2 step 5); until then it is not run.
* **Merging new passwords at an upgrade** (`kolla-mergepwd`) is added with the first bump that
  needs it.

### Consequences

* Good, because the passwords exist as files only in OpenBao and its backups, and on the
  bastion's tmpfs without swap while Kolla runs. They are on no disk, command line or log.
* Good, because an `init` cannot overwrite existing passwords, and nothing on the bastion can
  change or destroy one: a stolen bastion can read the passwords, not alter them.
* Good, because the daily snapshot already backs them up off-site.
* Bad, because the memory of the processes that hold the passwords can still be swapped to the
  bastion's swap file (ADR-0030: the bastion relies on swap during large Ansible runs):
  * `ansible-playbook` and its forks, which load them as extra variables;
  * the helper's Python.

  The owner accepted this on 2026-11-28. The swap file is on the bastion's disk, in
  `vg_akasha` on `insa`, and nothing backs it up. Whoever can read that disk is root on
  `insa` and can read the VM's memory anyway.
* Bad, because the operator's password now also opens every password of the cloud. Its reach
  is still limited to the bastion's address and 15-minute tokens, and the response to a
  stolen bastion (runbook `bastion.md`) gains a step: change the cloud's passwords.
* Bad, because changing a password needs the admin's token through the tunnel, and so does
  undoing a failed `init` (runbook).
* Bad, because no deployment can start while OpenBao is sealed (as for SSH certificates).
* Bad, because one more helper and one more mount must be kept in step with Kolla at each
  bump:
  * a new template;
  * `kolla-mergepwd` when a release adds passwords;
  * the blank key.

### Confirmation

In a container (Debian 13 with systemd, OpenBao 2.7.3 with TLS, configured like the lab):
* the bastion's roles run on a new VM, twice, the second time with `changed=0`, and a dry run
  changes nothing;
* `init` writes every non-blank value, `read` gives back the same file, and a second `init`
  refuses;
* the operator can neither change nor delete nor destroy a secret;
* the token and the passwords never appear in the process list;
* Ansible's temporary files of a template and a copy on the deployment host land on the tmpfs,
  none under `~/.ansible`.

On the lab:
* the plan of stack `openbao` creates the mount and the policy and updates the operator's
  token fields; a second plan is empty;
* the bastion's role runs twice, the second time with `changed=0`, and
  `findmnt /run/akasha-kolla` shows `noswap`;
* `init` once, then `read` gives the same values without printing them;
* `kolla-ansible gather-facts` runs with the passwords, then `clean` leaves nothing.

Open question A5 is then answered.

## More Information

* **The independent review** (2026-11-28) ran the helper against its own OpenBao 2.7.3. Its
  findings, all handled before anything ran on the lab:
  * Ansible's temporary files on the disk (blocker): moved to the tmpfs;
  * swapped process memory (blocker): accepted and stated (Consequences);
  * `post-deploy`'s files: ignored by git, removed by `clean`;
  * a failed `init` could not be retried: it now checks before writing, and the runbook gives
    the admin's recovery;
  * updates could push a value out of KV v2: the operator gets no `update`;
  * this ADR did not match the code (the policy's name, the plan);
  * a dry run on a new VM failed;
  * smaller points:
    * an older copy after a failed `read`;
    * temporary files with fixed names;
    * core dumps;
    * the expiry service's hardening;
    * the runbook's details.
* **Found while testing the fixes:** Ansible creates `local_tmp` when it starts, also for
  `ansible-galaxy`. The role `bastion_toolchain` installs Kolla's collections before the
  tmpfs exists, so that task uses the user's usual directory (`ANSIBLE_LOCAL_TEMP`).
* Kolla-Ansible 2026.1, "Operating Kolla", section on passwords:
  https://docs.openstack.org/kolla-ansible/2026.1/user/operating-kolla.html
* Source at the pinned commit: `kolla_ansible/cmd/readpwd.py`, `writepwd.py`, `genpwd.py`,
  `hashi_vault.py`, `ansible/post-deploy.yml`, `ansible/action_plugins/merge_configs.py`,
  `tests/test-openbao-passwords.sh`.
* OpenBao, "KV secrets engine - version 2": https://openbao.org/docs/secrets/kv/kv-v2/
* Linux 6.12, `Documentation/filesystems/tmpfs.rst` (`noswap`).
* ADR-0011 (OpenBao), ADR-0030 (swap), ADR-0047 (the lab's CA), ADR-0049 (OpenBao's backups),
  ADR-0050 (the operator), ADR-0051 (Kolla's toolchain).
