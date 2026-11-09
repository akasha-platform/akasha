# Kolla-Ansible configuration

Phase P2. This folder becomes the `--configdir` of `kolla-ansible` (2026.1 "Gazpacho"),
installed in a pinned virtualenv on the bastion (pin method: open question B5).

```
globals.yml
globals.d/10-network.yml  20-tls.yml  30-services.yml  40-tuning.yml
config/                    service overrides (galera.cnf, nova/nova-compute.conf, …)
multinode                  V1b inventory: 1 controller + 2 computes, 3 OVN gateway chassis
```

`passwords.yml` is **never** committed: it is generated, stored in OpenBao KV v2
(`kolla-writepwd`) and materialised on tmpfs only for a deployment run (`kolla-readpwd`).

Reference snippets: [research/03](../../docs/research/03-kolla-2026.1-findings.md).
