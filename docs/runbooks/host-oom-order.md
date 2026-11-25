# OOM order of the lab VMs on `insa`

Design: [ADR-0043](../adr/0043-oom-order-of-the-lab-vms.md). Managed by the Ansible role
`host_oom_order` (`infra/ansible/playbooks/host.yml`, tag `oom`).

`akasha-oom-order.timer` runs `/usr/local/sbin/akasha-oom-order` 30 s after boot and every 30 s
after that. The script sets the `oom_score_adj` of the QEMU process of each domain in
`machine-akasha.slice`. Values from most to least expendable:

| VM | os-cmp02 | os-cmp01 | os-ctl01 | bastion | core | router |
|---|---|---|---|---|---|---|
| `oom_score_adj` | 1000 | 800 | 600 | 500 | 400 | 300 |

When `insa` runs out of memory, the kernel kills os-cmp02's QEMU first: the VM stops as if
unplugged. The desktop's user processes have 200 (systemd), so they are killed after all of
akasha's VMs, unless one of them holds more than about 5.6 GiB.

## Run the role

```bash
cd infra/ansible
uv run ansible-playbook playbooks/host.yml -K --check --diff --tags oom
uv run ansible-playbook playbooks/host.yml -K --tags oom
```

The run applies the order at once, then checks every running lab VM's value, the timer, and
the timer's last result.

## Check

```bash
for n in router bastion core os-ctl01 os-cmp01 os-cmp02; do p=$(pgrep -f "guest=$n,"); echo "$n adj=$(cat /proc/$p/oom_score_adj) score=$(cat /proc/$p/oom_score)"; done
systemctl is-active akasha-oom-order.timer; systemctl show -P Result akasha-oom-order.service
journalctl -u akasha-oom-order --since -1h       # one line per change, warnings; no Started/Finished
```

`/proc/<pid>/oom_score` shows `(1000 + badness) × 2/3`, with the badness in thousandths of RAM
plus swap, `oom_score_adj` included (Linux `fs/proc/base.c`).

## Failure modes

* **A restarted VM** gets a new QEMU process with 0. The next run, within 30 s, sets it again
  and logs `<name>: pid <pid> oom_score_adj 0 -> <value>`.
* **The service fails** (`systemctl --failed`, a warning every 30 s):
  * `<name>: not in the table`: a new lab domain. Add it to `host_oom_order_adj` (role
    defaults) and run the role.
  * `<name>: no QEMU process found in its scope`: the VM was stopping, or QEMU's command line
    no longer contains `guest=<name>,`. The other VMs are still handled.

  Either way, nothing outside `machine-akasha.slice` is touched, and a VM that is not handled
  only keeps 0, as without this role.
* **An OOM kill happened**: `journalctl -k | grep -i 'out of memory'` names the victim. Start
  the VM again (runbook `lab-vms.md`). For `core`, unseal OpenBao afterwards (runbook
  `core.md`).

## Remove

```bash
sudo systemctl disable --now akasha-oom-order.timer
sudo rm /etc/systemd/system/akasha-oom-order.{service,timer} /usr/local/sbin/akasha-oom-order
sudo systemctl daemon-reload
```

The values already set stay until each VM's QEMU process restarts. To clear them at once, as
root: `echo 0 > /proc/<pid>/oom_score_adj` for each VM.
