# Reboot insa

Policy (open question C6, decided by the owner on 2026-11-27): `insa` is rebooted only while the
owner is on campus, near the machine. If Tailscale or SSH does not come back, the only way in is
its own screen and keyboard. Unattended upgrades never reboot; `/var/run/reboot-required` says
when a new kernel waits. The VMs never start with the host (ADR-0033): the owner starts them by
hand, router first, then unseals OpenBao (ADR-0011).

Every command runs on the laptop, from the repository, one at a time. Any command that prints
from `insa` uses `-o LogLevel=error`, so that SSH's "Connection to … closed" never shows its
address. `virsh` and other tools run with `LC_ALL=C`: `insa`'s locale is French.

```bash
cd ~/Documents/dev/Projets/akasha && mkdir -p ~/akasha-private/reboot && chmod 700 ~/akasha-private/reboot
state() {   # state <name>: the read-only snapshot of infra/scripts/insa-state.sh, shown and kept
  local f=~/akasha-private/reboot/"$1".txt
  ssh -o LogLevel=error insa 'cat > /tmp/akasha-state.sh' < infra/scripts/insa-state.sh &&
  ssh -t -o LogLevel=error insa 'sudo bash /tmp/akasha-state.sh' | tee "$f.raw" &&
  tr -d '\r' < "$f.raw" | grep -v '^\[sudo\]' > "$f" && rm -f "$f.raw"   # sudo's prompt shares the terminal
}
lv() { ssh -o BatchMode=yes -o LogLevel=error insa "LC_ALL=C virsh -c qemu:///system $*"; }
```

## 1. Before: who is on the machine, and the lab's state

The snapshot first. Its name stays in a file, for a new terminal after the reboot.

```bash
echo "$(date -u +%Y%m%dT%H%MZ)" > ~/akasha-private/reboot/current; state "$(cat ~/akasha-private/reboot/current)-before"
```

Check in it:
* the `sessions` lines, by kind. `class=greeter` is only the desktop's login screen,
  `class=manager` is systemd's per-user service manager (not a person), and the owner's SSH
  shows as `remote=yes`. A `class=user` with `remote=no` means someone is logged in
  on the machine itself (the school's desktop): ask before going on, since a reboot ends it;
* `akasha_firewall=active enabled`, `tailscaled=active enabled`;
* every VM, `linux2024` included, has `autostart=disable` and `managed_save=no`. A saved
  `core` would resume unsealed;
* `libvirt_guests=enabled` with the effective `ON_BOOT=ignore ON_SHUTDOWN=shutdown` (Debian's
  defaults: a host shutdown stops the guests cleanly and never restarts or saves them).

Then stop the lab VMs, the router last. OpenBao seals when `core` stops; the backups resume once
it is unsealed.

```bash
for vm in os-cmp02 os-cmp01 os-ctl01 bastion core router; do
  lv shutdown "$vm" >/dev/null
  for i in $(seq 60); do [ "$(lv domstate "$vm")" = "shut off" ] && break; sleep 2; done
  s=$(lv domstate "$vm"); echo "$vm: $s"; [ "$s" = "shut off" ] || { echo "STOP: $vm still runs"; break; }
done
```

Each line must say `shut off`. On `STOP`, look at that VM's serial console (runbook
`lab-vms.md`); `virsh destroy` is the last resort.

## 2. Reboot

```bash
ssh -t -o LogLevel=error insa 'sudo systemctl reboot'
until ! ssh -o BatchMode=yes -o ConnectTimeout=5 -o LogLevel=error insa true 2>/dev/null; do sleep 5; done; echo "insa is down"
until ssh -o BatchMode=yes -o ConnectTimeout=5 -o LogLevel=error insa true 2>/dev/null; do sleep 10; done; echo "insa is back"
```

If it is not back within 15 minutes, go to the machine.

## 3. After: compare

```bash
t=$(cat ~/akasha-private/reboot/current); state "$t-after"
diff ~/akasha-private/reboot/$t-before.txt ~/akasha-private/reboot/$t-after.txt
```

The only expected differences are `boot_id`, which **must** differ (it proves the reboot), the
`sessions` lines, plus `kernel` and `reboot_required` after a kernel update. Anything else is a
finding:
* a missing bridge or route, or a bridge with IPv6 or the wrong forwarding;
* `akasha_firewall` not `active`, or `nft_table_inet_akasha=0`. **Then do not start the
  router**: without the table the lab is routed without filter or NAT (runbook
  `host-firewall.md`);
* Tailscale not advertising both lab routes.

Then the host's roles, dry run first. `oom` comes after the VMs (its checks need them).

```bash
cd infra/ansible
uv run --locked ansible-playbook playbooks/host.yml -K --check --diff --skip-tags oom -e @~/akasha-private/host_firewall.yml
uv run --locked ansible-playbook playbooks/host.yml -K --skip-tags oom -e @~/akasha-private/host_firewall.yml   # changed=0
cd ../..
```

## 4. Start the lab, the router first

```bash
for vm in router core bastion os-ctl01 os-cmp01 os-cmp02; do
  case $vm in router) ip=10.10.0.1;; core) ip=10.10.0.12;; bastion) ip=10.10.0.10;;
    os-ctl01) ip=10.10.0.11;; os-cmp01) ip=10.10.0.21;; os-cmp02) ip=10.10.0.22;; esac
  lv start "$vm" >/dev/null
  for i in $(seq 60); do ssh -o BatchMode=yes -o ConnectTimeout=3 -o LogLevel=error debian@$ip true 2>/dev/null && break; sleep 5; done
  s=$(ssh -o BatchMode=yes -o ConnectTimeout=3 -o LogLevel=error debian@$ip 'systemctl is-system-running --wait' 2>&1)
  echo "$vm: $s"; [ "$vm" != router ] || [ "$s" = running ] || { echo "STOP: the router is not up"; break; }
done
```

Each line should say `running`. `degraded` names a failed unit: run `systemctl --failed` on that
VM. Then:
1. Unseal OpenBao with two shares (runbook `core.md`, "Unseal").
2. The OOM order: `cd infra/ansible && uv run --locked ansible-playbook playbooks/host.yml -K --tags oom; cd ../..`
   should report `changed=0` once the timer has run (runbook `host-oom-order.md`).
3. One backup:
   `ssh -o LogLevel=error debian@10.10.0.12 'sudo systemctl start akasha-openbao-backup; systemctl show -P Result akasha-openbao-backup.service'`
   should print `success`.
4. The router's time: `ssh -o LogLevel=error debian@10.10.0.1 'chronyc -c tracking | cut -d, -f3,14'` shows a
   stratum and `Normal`.

## 5. Record

Keep the state files in `~/akasha-private/reboot/`. The newest `-after.txt` is also the reference
for an unplanned reboot (school IT, power cut): compare a fresh `state` with it. Note the reboot
and any finding in the ADR of the step (A17: ADR-0008 Updates).
