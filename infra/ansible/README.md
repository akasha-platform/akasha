# Ansible

Planned structure (created when each phase starts):

```
ansible.cfg
collections/requirements.yml   pinned collections (e.g. k3s.orchestration by commit SHA)
inventories/lab/               hosts and group_vars (generated parts are not committed)
playbooks/                     host.yml (P1), bastion.yml (P1), core.yml (P1), k3s.yml (P4)
roles/                         host bridges + nftables, memory headroom, OpenBao, versitygw, …
```

Commands that touch the host are run by the owner; outputs are reviewed before moving on.
