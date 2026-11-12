# Ansible

Host configuration as code (ADR-0026). Commands run from this directory.

```
ansible.cfg
collections/requirements.yml   pinned collections, incl. transitive ones (installed copy is git-ignored)
inventories/lab/hosts.yml      hosts by SSH alias (no address committed)
playbooks/                     facts.yml (read-only); host.yml (P1), bastion.yml, core.yml (P1), k3s.yml (P4)
roles/                         host storage, bridges + nftables, memory headroom, OpenBao, versitygw, …
```

```bash
cd infra/ansible
uv run ansible-galaxy collection install -r collections/requirements.yml -p collections   # once per clone / after a bump
uv run ansible insa -m ansible.builtin.ping
uv run ansible-playbook playbooks/facts.yml
uv run ansible-playbook playbooks/<name>.yml --check --diff -K   # always dry-run first
```

Commands that change the host are run by the owner; outputs are reviewed before moving on.
