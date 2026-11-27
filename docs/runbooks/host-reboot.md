# Reboot insa

Policy (open question C6, decided by the owner on 2026-11-27): `insa` is rebooted only while the
owner is on campus, near the machine. If Tailscale or SSH does not come back, the only way in is
its own screen and keyboard. Unattended upgrades never reboot; `/var/run/reboot-required` says
when a new kernel waits. The VMs never start with the host (ADR-0033): the owner starts them by
hand, router first, then unseals OpenBao (ADR-0011).

Every command runs on the laptop, from the repository, one at a time.

## 1. Before: record the state

```bash
mkdir -p -m 700 ~/akasha-private/reboot && t=$(date -u +%Y%m%dT%H%MZ)
ssh -t insa 'sudo bash -s' < infra/scripts/insa-state.sh | tee ~/akasha-private/reboot/$t-before.txt
```

The script is read-only. It prints, in a fixed order, the kernel, the bridges (state, IPv6,
forwarding, NetworkManager), `ip_forward`, the libvirt `default` network, the firewall and its
guard rule, the lab routes, Tailscale's advertised routes and firewall mode, the images mount,
the pool, the `akasha-*` units and every VM with its state and autostart. Every VM, including
`linux2024`, must show `autostart=disable`.

## 2. Stop the lab VMs, the router last

OpenBao seals when `core` stops. The backups resume once it is unsealed again.

```bash
for vm in os-cmp02 os-cmp01 os-ctl01 bastion core router; do
  ssh -o BatchMode=yes insa "virsh -c qemu:///system shutdown $vm" >/dev/null
  for i in $(seq 60); do [ "$(ssh -o BatchMode=yes insa "virsh -c qemu:///system domstate $vm")" = "shut off" ] && break; sleep 2; done
  echo "$vm: $(ssh -o BatchMode=yes insa "virsh -c qemu:///system domstate $vm")"
done
```

Each line must say `shut off`. If a VM does not stop within two minutes, look at its serial
console (runbook `lab-vms.md`) before going on; `virsh destroy` is the last resort.

## 3. Reboot

```bash
ssh -t insa 'sudo systemctl reboot'
```

Then wait for `insa` in the tailnet (a few minutes): `until ssh -o BatchMode=yes -o ConnectTimeout=5 insa true 2>/dev/null; do sleep 10; done; echo back`.
If it does not come back within 15 minutes, go to the machine.

## 4. After: compare the state

```bash
ssh -t insa 'sudo bash -s' < infra/scripts/insa-state.sh | tee ~/akasha-private/reboot/$t-after.txt
diff ~/akasha-private/reboot/$t-before.txt ~/akasha-private/reboot/$t-after.txt
```

Expected differences: `kernel` and `reboot_required` (after a kernel update), the VMs'
`state=running` becoming `state=shut_off`, and the units that only run at times (timers'
services). Anything else is a finding:
* a missing bridge or route;
* `akasha_firewall` not `active`, or `nft_table_inet_akasha=0`. **Then do not start the
  router**: without the table the lab is routed without filter or NAT (runbook
  `host-firewall.md`);
* Tailscale not advertising both lab routes.

Then the host's roles: their checks pass and nothing changes.

```bash
cd infra/ansible && uv run --locked ansible-playbook playbooks/host.yml -K -e @~/akasha-private/host_firewall.yml   # changed=0
```

## 5. Start the lab, the router first

```bash
for vm in router core bastion os-ctl01 os-cmp01 os-cmp02; do
  ssh -o BatchMode=yes insa "virsh -c qemu:///system start $vm" >/dev/null
  ip=$(case $vm in router) echo 10.10.0.1;; core) echo 10.10.0.12;; bastion) echo 10.10.0.10;; os-ctl01) echo 10.10.0.11;; os-cmp01) echo 10.10.0.21;; os-cmp02) echo 10.10.0.22;; esac)
  for i in $(seq 60); do ssh -o BatchMode=yes -o ConnectTimeout=3 debian@$ip true 2>/dev/null && break; sleep 5; done
  echo "$vm: $(ssh -o BatchMode=yes -o ConnectTimeout=3 debian@$ip 'systemctl is-system-running' 2>&1)"
done
```

Each line should say `running` (`degraded` names a failed unit: `systemctl --failed` on it).

Then:
1. Unseal OpenBao with two shares (runbook `core.md`, "Unseal").
2. Start one backup and read it:
   `ssh debian@10.10.0.12 'sudo systemctl start akasha-openbao-backup; systemctl show -P Result akasha-openbao-backup.service'`
   should print `success`.
3. Check the router's time (`chronyc tracking` on the router: Leap Normal) and the OOM order
   (runbook `host-oom-order.md`, "Check").

## 6. Record

Keep both state files in `~/akasha-private/reboot/`. Note the reboot and any finding in the ADR of
the step (A17: ADR-0008 Updates).
