# Runbooks

One runbook per alert or known failure mode, written when the failure mode is introduced.

## Template

```markdown
# <Title of the failure>

- **Symptom:** what the alert or the operator sees
- **Impact:** what is broken for whom
- **Diagnosis:** commands to run, what to look for
- **Mitigation:** steps to restore service
- **Escalation / rollback:** what to do if mitigation fails
- **Links:** ADRs, research notes, dashboards
```

## Index

* [opentofu-l0.md](opentofu-l0.md) — OpenTofu L0 stack: passphrase in the keyring, init/plan/apply,
  checks of the encrypted state and the lock, off-AWS copy, provider supply chain, roll back
* [host-storage.md](host-storage.md) — host LVM storage: images volume not mounted, restore the
  partition table, undo the layout, grow `lv_images`
* [host-network.md](host-network.md) — lab bridges: check, missing bridge, change a bridge
  safely, overlay MTU, NetworkManager taking a bridge
* [aws-l0-state.md](aws-l0-state.md) — AWS bucket and IAM users for the L0 OpenTofu state:
  administrator user, bucket, least-privilege user, read-back, checks, roll back
* [host-firewall.md](host-firewall.md) — lab firewall and NAT: run with the private campus
  prefixes, check after reboot, what removes the rules, test with a fake lab VM, roll back
* [host-tailscale.md](host-tailscale.md) — Tailscale subnet routes to the lab: what is set,
  tailnet policy template, check, test with a fake lab router, overlapping local network, roll
  back
* [host-upgrade.md](host-upgrade.md) — upgrade `insa` (Debian point releases) and reboot safely
  over Tailscale; stale package lists
* [lab-vms.md](lab-vms.md) — lab VMs: console password, Ansible runs, serial console, add a
  VM (host key check), locked out of SSH, roll back `vm_base`
* [bastion.md](bastion.md) — bastion: the `akasha` user, update the code, run a playbook from
  the bastion, bump the pinned mise
* [core.md](core.md) — `core`: OpenBao (state, checks, bump the pinned version, restart of an
  initialised OpenBao), host firewall
* [router.md](router.md) — edge router DNS (Unbound), time (chrony), firewall and forwarding:
  run, check, DNS not answering, add a name, lost time sources, commit-confirmed loading,
  locked out, fake-client test, roll back
