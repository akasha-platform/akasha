# infra

Infrastructure as code, organised by tool and by layer (see
[ADR-0021](../docs/adr/0021-repository-layout.md)).

| Folder | Tool | Layers | First used in |
|---|---|---|---|
| [opentofu/](opentofu/README.md) | OpenTofu | L0 host VMs, L1 OpenStack VMs, L2 OpenStack resources, L3 K8s VMs | P1 |
| [ansible/](ansible/README.md) | Ansible | host, bastion, core, K3s | P1 |
| [kolla/](kolla/README.md) | Kolla-Ansible 2026.1 | L1 OpenStack services | P2 |
