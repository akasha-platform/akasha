# OpenTofu

Planned structure (created when each phase starts):

```
modules/                      reusable modules (libvirt VM, OpenStack network, K8s node pool, …)
live/
  l0-host/                    libvirt VMs on the host: router, bastion, core, ctl, computes     (P1; L1 merged here)
  l2-openstack-resources/     projects, users, app credentials, networks, images, flavors        (P3)
  l3-k8s/                     K3s VMs, ports, server groups, floating IPs                         (P4)
```

Rules (ADR-0007):

- One state per layer. L1 is merged into L0. L2 and L3 are applied by CI, which runs `tofu` on
  the bastion; their states live in a second AWS S3 bucket with `use_lockfile`, encrypted with
  OpenBao Transit (ADR-0032).
- The L0/bootstrap state cannot live in the S3 it creates: it lives in a dedicated AWS S3
  bucket with `use_lockfile` and versioning (ADR-0031). Only the owner applies L0, from the
  laptops; the bucket name, region and account ID stay outside the repository (partial
  backend configuration in `~/akasha-private/`, passed with `-backend-config=`).
- State is encrypted client-side (OpenBao Transit; `pbkdf2` passphrase for the bootstrap stack).
- Providers pinned: `dmacvicar/libvirt = 0.9.9`, `terraform-provider-openstack/openstack ~> 3.4`.
- Never commit `*.tfstate`, `*.tfvars` or plans (see `.gitignore`).
