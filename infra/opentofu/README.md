# OpenTofu

Planned structure (created when each phase starts):

```
modules/                      reusable modules (libvirt VM, OpenStack network, K8s node pool, …)
live/
  l0-host/                    libvirt VMs on the host: OPNsense, bastion, core, ctl, computes   (P1)
  l1-openstack-vms/           reserved if OpenStack node VMs are split from l0-host               (P1–P2)
  l2-openstack-resources/     projects, users, app credentials, networks, images, flavors        (P3)
  l3-k8s/                     K3s VMs, ports, server groups, floating IPs                         (P4)
```

Rules (ADR-0007):

- One state per layer. L1–L3 states live in the in-lab S3 with `use_lockfile`.
- The L0/bootstrap state cannot live in the S3 it creates; its first apply runs from the
  operator laptop and its location is open question B3.
- State is encrypted client-side (OpenBao Transit; `pbkdf2` passphrase for the bootstrap stack).
- Providers pinned: `dmacvicar/libvirt = 0.9.9`, `terraform-provider-openstack/openstack ~> 3.4`.
- Never commit `*.tfstate`, `*.tfvars` or plans (see `.gitignore`).
