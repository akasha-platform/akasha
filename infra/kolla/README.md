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

`passwords.yml` is **never** committed or written to a disk: it lives in OpenBao KV v2 and is
only a link to a tmpfs without swap during a run, made by `akasha-kolla-passwords`
([ADR-0052](../../docs/adr/0052-kolla-passwords-in-openbao.md), runbook `bastion.md`). Never run
`kolla-genpwd`, `kolla-readpwd` or `kolla-mergepwd` on it: they replace the link with a plain
file on the disk.

The APIs' TLS ([ADR-0053](../../docs/adr/0053-openstack-api-tls-and-vips.md)): two VIPs
(`api-int.akasha.internal` 10.10.0.100, `api.akasha.internal` 10.10.0.101), HTTPS on both
(`globals.d/20-tls.yml`), and TLS to MariaDB through ProxySQL. `read` also writes HAProxy's and
ProxySQL's certificate files, from OpenBao, to `kolla_certificates_dir` on the same tmpfs. Never
run `kolla-ansible` with `--diff`: it prints the files it copies, keys and passwords included. Never run `kolla-ansible certificates`: it makes its
own test CA and unencrypted keys.

Reference snippets: [research/03](../../docs/research/03-kolla-2026.1-findings.md).
