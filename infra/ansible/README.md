# Ansible

Host configuration as code (ADR-0026). Commands run from this directory.

```
ansible.cfg
collections/requirements.yml   pinned collections, incl. transitive ones (installed copy is git-ignored)
inventories/lab/hosts.yml      insa by SSH alias (no address committed); lab VMs by lab address
playbooks/                     facts.yml (read-only); host.yml, router.yml, core.yml, bastion.yml (P1); k3s.yml (P4)
roles/                         host_storage, host_network, host_firewall, vm_base, router_dns, router_time, router_firewall, lab_client, vm_data_disk, vm_swap (P1); later memory headroom, OpenBao, versitygw, …
```

```bash
cd infra/ansible
uv run ansible-galaxy collection install -r collections/requirements.yml -p collections   # once per clone / after a bump
uv run ansible insa -m ansible.builtin.ping
uv run ansible-playbook playbooks/facts.yml
uv run ansible-playbook playbooks/<name>.yml --check --diff -K   # always dry-run first
```

Commands that change the host are run by the owner; outputs are reviewed before moving on.

Host storage (ADR-0009, runbook `docs/runbooks/host-storage.md`): the partition is created
only when the disk name is confirmed explicitly, after the dry run was reviewed:

```bash
uv run ansible-playbook playbooks/host.yml -K --check --diff
uv run ansible-playbook playbooks/host.yml -K -e host_storage_confirm=nvme0n1
```

Lab VMs (ADR-0035, runbooks `docs/runbooks/lab-vms.md` and `docs/runbooks/router.md`): no
`-K` (passwordless sudo); the console password hash comes from a private file:

```bash
uv run ansible-playbook playbooks/router.yml --check --diff -e @~/akasha-private/lab_vms.yml
```
