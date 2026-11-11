---
status: accepted
date: 2026-11-12
decision-makers: dhuy21
---

# Ansible conventions for host configuration

## Context and Problem Statement

From P1 on, the physical host `insa` (disk layout, bridges, nftables, memory headroom,
monitoring) and later the bastion and core VMs must be configured as code: idempotent,
reviewable in pull requests, dry-runnable, and reproducible from a fresh clone. Collections
must be pinned like every other tool (ADR-0022), and nothing that identifies the campus
network may be committed.

## Considered Options

* Ansible (ansible-core 2.20, already locked in `uv.lock` for kolla-ansible 2026.1)
* One-off shell scripts (not idempotent, no dry run)
* The `ansible` community package from PyPI as the source of collections: rejected, because
  14.x requires ansible-core 2.21 and 13.x (ansible-core 2.20) stopped receiving releases in
  June 2026

## Decision Outcome

Chosen option: "Ansible", laid out under `infra/ansible/`:

* `ansible.cfg` (commands run from `infra/ansible/`): inventory `inventories/lab/hosts.yml`,
  `collections_path = collections`, `collections_scan_sys_path = false` (never fall back to
  collections installed elsewhere), host key checking on, `/usr/bin/python3` on targets.
* **Inventory without addresses**: hosts point to SSH aliases of the operator's
  `~/.ssh/config` (`ansible_host: insa`), reached over Tailscale.
* **Collections** in `collections/requirements.yml`, pinned to exact versions **including
  transitive dependencies** (community.general 13.5.1, ansible.posix 2.2.2,
  community.library_inventory_filtering_v1 1.1.5), installed into
  `collections/ansible_collections/` (git-ignored). `ansible-galaxy` checks every download
  against the SHA-256 published by Galaxy (`concrete_artifact_manager.py`, ansible-core
  2.20); Galaxy publishes no signatures for these collections. Renovate updates the pins with
  the 6-day cooldown (ADR-0024).
* `.ansible-lint`: profile `production`, `offline: true`; CI installs the pinned collections
  before pre-commit. trivy skips the installed collections (third-party test fixtures).
* **Runs**: from the owner's laptop, `--check --diff` first, privilege escalation with `sudo`
  and the password prompted (`-K`); no become password or secret in the repository.
  Destructive roles (disk partitioning) carry explicit guards and are run only after the
  owner confirms the dry-run output.

### Consequences

* Good, because host changes become reviewable, repeatable and checkable (`--check`, a second
  run reports no change).
* Bad, because collections from Galaxy are trusted on Galaxy's TLS and published hash only;
  a stricter self-managed hash lock was considered and not adopted (Renovate could not
  refresh it).

### Confirmation

* `ansible-lint` (production profile) passes; `ansible-inventory --graph` and
  `--syntax-check` succeed; CI installs the collections and passes.
* Read-only check from the laptop: `ansible insa -m ansible.builtin.ping` and
  `playbooks/facts.yml` (to be recorded once run by the owner).
