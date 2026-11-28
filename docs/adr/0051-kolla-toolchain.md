---
status: accepted
date: 2026-11-28
decision-makers: dhuy21
---

# Kolla-Ansible's toolchain: a stable/2026.1 commit, the repository's Python, its own collections

## Context and Problem Statement

Kolla-Ansible 2026.1 (ADR-0004) runs on the bastion as `akasha` (ADR-0040) and reaches the
OpenStack nodes with certificates from OpenBao (ADR-0050). It is a Python package with three
parts:
* the `kolla-ansible` command, which runs the playbooks shipped in the package with
  `ansible-playbook`;
* the Ansible collections those playbooks need;
* a configuration directory (`--configdir`): `globals.yml`, `globals.d/`, `passwords.yml` and
  the inventory.

Every tool of the repository is pinned (ADR-0022). Three points were open:
* how kolla-ansible is pinned (open question B5);
* on which Python it runs;
* how its collections are installed.

Facts checked on 2026-11-28:
* **Releases** (PyPI).
  * 22.2.0 (2026-09-08) is the latest 2026.1 release.
  * 23.0.0 (2026.2) came out on 2026-10-21. 2026.1 stays the target: it is a SLURP release,
    upgradable straight to 2027.1 (ADR-0004).
* **Unreleased fixes** (opendev).
  * `stable/2026.1` holds about 40 commits after 22.2.0, among them "Fix MariaDB cluster
    recovery" (2026-11-27), "Include CA for database TLS on MariaDB backup", "Fix container
    unhealthy checks" and a longer MariaDB healthcheck start period.
  * These touch the cold boot and the backups of P2 step 8.
  * Upstream recommends installing from the stable branch (`operating-kolla.rst`).
* **Python.**
  * 22.2.0 declares `python_requires >=3.11`, and its classifiers list only 3.11 and 3.12.
    23.0.0 lists 3.12 to 3.14.
  * The repository uses Python 3.14 (ADR-0022). On the laptop, with Python 3.14.10 and
    ansible-core 2.20:
    * 22.2.0 installs, `kolla-ansible --version` and `kolla-genpwd` run, and
      `ansible-playbook --syntax-check` passes on `site.yml` and `kolla-host.yml`;
    * its unit tests pass: 449 passed, 2 skipped, 0 failed (`stestr run`, as upstream's
      `tox` runs them).
  * VERIFIED for these checks. A real deployment on 3.14 is still untested (INFERRED to work).
* **ansible-core.** Kolla requires `>=2.19,!=2.19.0,<2.21`. The repository's 2.20 fits.
* **uv and git.** uv pins a git dependency by commit: a `stable/2026.1` commit installs as
  `22.2.1.dev38`, with the playbooks in `share/kolla-ansible`. `uv.lock` records the commit,
  not a file hash, and uv's `exclude-newer` (the cooldown) does not apply to git sources.
* **`kolla-ansible install-deps`** (`kolla_ansible/utils.py`, `requirements*.yml`):
  * it installs the collections by version range (`community.general <12`, …);
  * it takes `openstack.kolla` from the moving `stable/2026.1` branch;
  * it installs into `~/.ansible/collections`, with `--force`.
* **Conflict.** Kolla needs `community.general <12`; the repository pins 13.5.1 (ADR-0026).
* **Passwords.** Every `kolla-ansible` command reads `passwords.yml` and stops without it
  (`kolla_ansible/ansible.py`), so the passwords of step 3 come first.
* **OpenBao.** Upstream's CI runs `kolla-writepwd` and `kolla-readpwd` against OpenBao
  (`tests/test-openbao-passwords.sh`), which is useful for step 3.
* **Network interfaces.** The three nodes name their NICs `mgmt`, `tun` and `ext` (ADR-0041),
  so one set of interface names serves all of them.

## Decision Drivers

* The same toolchain on every run (ADR-0022), with the 6-day cooldown.
* The fixes the deployment and its operations need.
* As few environments to maintain as possible; the laptop and CI do not need Kolla.
* Nothing installed from a moving reference.

## Considered Options

* **Pin:**
  * **a commit of `stable/2026.1`**;
  * the PyPI release 22.2.0.
* **Python:**
  * **the repository's project and Python 3.14, in a dependency group `kolla`**;
  * a project of its own on Python 3.12, the version upstream tests.
* **Collections:**
  * **a requirements file of Kolla's own, pinned to exact versions, in a collections directory
    of its own**;
  * `kolla-ansible install-deps`.
* **Scope on the lab of P2 step 2:**
  * **the bastion's tools and an Ansible ping of the nodes through Kolla's inventory**;
  * also `kolla-ansible bootstrap-servers` (Docker on the nodes).

## Decision Outcome

Chosen by the owner on 2026-11-28 (the options in bold).

* **kolla-ansible** is a git dependency at commit
  `d9658dc9c5c13c151ed3ecb77ac7796afd30e2fe` of `stable/2026.1` (merged 2026-11-17, past the
  cooldown). It lives in a dependency group `kolla` of the repository's `pyproject.toml`, on
  Python 3.14 and the repository's ansible-core 2.20. Only the bastion installs that group
  (`uv sync --locked --group kolla`); the laptop and CI keep the default group.
* **Its collections** are pinned exactly in `infra/kolla/collections/requirements.yml` and
  installed into `infra/kolla/collections/` (git-ignored). Dependencies are included, and each
  version is past the cooldown:
  * `openstack.kolla` at commit `25c561e0c02cb073c0f60ee727c914fb49e02a17`, the head of its
    `stable/2026.1` on 2026-11-17;
  * the Galaxy collections of `requirements-core.yml` at the newest versions within its
    ranges that are past the cooldown, checked against Galaxy's SHA-256 by `ansible-galaxy`.

  `infra/kolla/ansible.cfg` points at them. `kolla-ansible` runs from `infra/kolla`, so it
  never loads the repository's collections. `install-deps` is not used.
* **Configuration.** `infra/kolla` holds a first `globals.yml` and `globals.d/` with what is
  settled:
  * `kolla_base_distro: debian`, `openstack_release: 2026.1`;
  * the interfaces `mgmt`, `tun` and `ext`;
  * OVN.

  It also holds the V1b inventory `multinode`. The open choices stay out until their step
  (B2 MTU and B4 VIPs: steps 4–5).
* **Step 2 on the lab** installs the tools on the bastion and pings the nodes through Kolla's
  inventory and `ansible.cfg`. Nothing is installed on the nodes.

### Consequences

* Good, because the deployment gets the fixes of `stable/2026.1`. The MariaDB recovery fix
  (2026-11-27) is taken in a bump after 2026-12-03, before step 8.
* Good, because one lock file and one Python serve the repository and Kolla, and the laptop
  and CI do not install Kolla.
* Good, because Kolla's collections never mix with the repository's, and none comes from a
  moving branch.
* Bad, because the cooldown of the two git commits is checked by hand: uv does not apply
  `exclude-newer` to git sources. Renovate does not follow them either. Each bump is a
  deliberate pull request.
* Bad, because a git commit has no file hash. The commit ID (SHA-1) and HTTPS to opendev.org
  are what pin it. The bastion needs opendev.org and galaxy.ansible.com when it installs.
* Bad, because 2026.1 is not tested upstream on Python 3.14. If the deployment fails because
  of it, the fallback is a project of its own on Python 3.12, which is a new decision.
* Bad, because some of Kolla's libraries in `uv.lock` are newer than OpenStack's
  upper-constraints of 2026.1 (cryptography 50.0.2 against 43.0.3, oslo.config 10.8.1 against
  10.3.0, cliff 4.17.0 against 4.13.3). They are the versions the unit tests passed with, and
  they run on the bastion only (the CLI, `kolla-readpwd`); the services run in Kolla's
  images. The owner chose on 2026-11-28 to keep them rather than apply the constraints, which
  would also lower the cryptography of the laptop's `keyring`. If one of them breaks Kolla,
  that library is lowered (INFERRED risk).
* Neutral: ansible-core stays capped below 2.21 while the repository runs Kolla 2026.1.

### Confirmation

On the laptop:
* `uv lock` resolves the group `kolla`;
* `uv sync --locked` without the group installs no Kolla;
* `ansible-playbook --syntax-check` passes on Kolla's `site.yml` with `infra/kolla`'s
  inventory, configuration and collections;
* CI's lint passes.

On the bastion, as `akasha`, from `infra/kolla`:
* `kolla-ansible --version` prints `22.2.1.dev38`;
* `ansible-galaxy collection list` shows exactly the pinned versions;
* with a certificate (ADR-0050), `ansible -i multinode all -m ping` reaches the three nodes,
  and `-m setup` reads their facts.

## More Information

* Kolla-Ansible 2026.1, "Quick Start for deployment/evaluation" and "Operating Kolla":
  https://docs.openstack.org/kolla-ansible/2026.1/
* Source, `stable/2026.1`: https://opendev.org/openstack/kolla-ansible/src/branch/stable/2026.1
  (`requirements.txt`, `requirements.yml`, `requirements-core.yml`, `setup.cfg`,
  `kolla_ansible/utils.py`, `kolla_ansible/ansible.py`).
* PyPI: https://pypi.org/project/kolla-ansible/#history
* Research notes: [research/03](../research/03-kolla-2026.1-findings.md).
* ADR-0004 (Kolla 2026.1), ADR-0022 (pinned toolchain), ADR-0026 (Ansible conventions),
  ADR-0040 (the bastion), ADR-0041 (the nodes' NICs), ADR-0050 (SSH from the bastion).
