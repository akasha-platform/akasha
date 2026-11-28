# Kolla-Ansible configuration

Phase P2. This folder is the `--configdir` of `kolla-ansible` 2026.1 "Gazpacho" (ADR-0004),
run on the bastion as `akasha` from this folder. The toolchain is in
[ADR-0051](../../docs/adr/0051-kolla-toolchain.md):
* kolla-ansible at a pinned `stable/2026.1` commit, in the dependency group `kolla` of the
  repository's `pyproject.toml` (installed on the bastion only);
* its own Ansible collections, pinned in `collections/requirements.yml`, with `ansible.cfg`
  pointing at them (never `kolla-ansible install-deps`).

```
ansible.cfg                Kolla's Ansible settings and collections path
collections/requirements.yml
globals.yml
globals.d/                 one file per topic (network, TLS, services, tuning)
config/                    service overrides (galera.cnf, nova/nova-compute.conf, …)
multinode                  V1b inventory: 1 controller + 2 computes, 3 OVN gateway chassis
```

`passwords.yml` is **never** committed: it is generated, stored in OpenBao KV v2
(`kolla-writepwd`) and materialised on tmpfs only for a deployment run (`kolla-readpwd`).

Reference snippets: [research/03](../../docs/research/03-kolla-2026.1-findings.md).
