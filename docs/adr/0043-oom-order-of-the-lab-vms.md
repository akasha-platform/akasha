---
status: accepted
date: 2026-11-24
decision-makers: dhuy21
---

# OOM order of the lab VMs on the school's host

## Context and Problem Statement

`insa` has no `systemd-oomd`, so only the kernel's OOM killer acts when memory runs out
([ADR-0030](0030-ram-budget.md)). libvirt never sets `oom_score_adj`, so every QEMU process
inherits 0 from `libvirtd` ([ADR-0016](0016-host-memory-headroom.md)). The kernel would
therefore kill the largest VM, the OpenStack controller, and with it Galera and RabbitMQ.
Killing `core` restarts OpenBao sealed, waiting for a manual unseal. ADR-0016 asks for a
per-VM order "so the least important VM is sacrificed first", decided after the RAM gate of
step 6 (open question A15).

Facts checked on 2026-11-24:

* **Kernel.** VERIFIED in Linux v6.12, `mm/oom_kill.c` and `fs/proc/base.c`.
  * A process's badness is its RSS plus swap plus page tables, in pages. Then
    `oom_score_adj × totalpages / 1000` is added, where `totalpages` is RAM plus swap.
  * The kernel kills the process with the highest badness. A process at -1000 is skipped.
  * `/proc/<pid>/oom_score` shows `(1000 + badness × 1000 / totalpages) × 2/3`.
* **`insa`.** Measured, read-only:
  * RAM plus swap is about 55.7 GiB. At full allocation, a VM's weight in thousandths is
    about 146 for os-ctl01, 137 for each compute, 14 for the bastion, 13 for `core` and 11 for
    the router.
  * The six QEMU processes have 0, in `machine.slice/machine-akasha.slice/<scope>/libvirt/emulator`.
  * The desktop's user processes already have **200**, from systemd 257.
* **libvirt hooks.** VERIFIED: https://libvirt.org/hooks.html.
  * A hook added while the daemon runs is used only after the daemon restarts.
  * A hook runs for every domain.
  * A failure in `prepare`, `start` or `started` stops the domain from starting.
* **Logging.** `LogLevelMax=` also filters what the service manager logs about the unit
  (VERIFIED: `systemd.exec(5)`, and tested with systemd 259 on the laptop).

## Decision Drivers

* Keep the VMs that are costly to lose: the router (the whole lab's gateway), `core` (OpenBao
  seals), the controller (the OpenStack control plane).
* [ADR-0027](0027-guest-on-the-school-host.md): akasha gives way before the school's
  processes, and touches neither libvirt nor `linux2024`.
* A broken mechanism must leave things as they are today, never stop a VM from starting.

## Considered Options

* **Order:**
  * computes first, then the controller, the bastion, `core` and the router;
  * protect only `core` and the router, with one value for the rest.
* **Mechanism:**
  * **a timer `akasha-oom-order`** that sets the value of running QEMU processes;
  * a libvirt hook in `/etc/libvirt/hooks/qemu.d/`.

## Decision Outcome

Chosen by the owner on 2026-11-24: **computes first**, with **the timer**.

* **Values** (role `host_oom_order`, `host.yml` tag `oom`):

  | VM | os-cmp02 | os-cmp01 | os-ctl01 | bastion | core | router |
  |---|---|---|---|---|---|---|
  | `oom_score_adj` | 1000 | 800 | 600 | 500 | 400 | 300 |

  * Each step is larger than the weight of the VM below it at full allocation, so the order
    holds whatever memory each VM holds.
  * The lowest value, 300, stays above the desktop's 200. A school process outranks the
    router only beyond about 5.6 GiB, and a root process (0) only beyond about 16.7 GiB.
* **The script** `/usr/local/sbin/akasha-oom-order`:
  * reads the domain names from the scopes in `machine-akasha.slice`;
  * finds each QEMU process with `pgrep -f "guest=<name>,"`;
  * writes only to a process whose `/proc/<pid>/cgroup` lies in that very scope.

  It is quiet when nothing changes and logs one notice line per change. It warns and exits 1
  when a domain has no value in the table, or when its QEMU process is not found.
* **The units.** `akasha-oom-order.service` is a oneshot with `LogLevelMax=notice`, which keeps
  systemd's "Starting/Finished" lines out of the school's journal. `akasha-oom-order.timer`
  runs it 30 s after boot and every 30 s after that.

### Consequences

* Good, because an OOM costs a compute first, and the router, `core` and the controller last.
* Good, because akasha's VMs give way before the school's processes, with positive values
  only.
* Good, because libvirt is neither changed nor restarted. A broken script leaves values at 0,
  as before.
* Bad, because a VM whose QEMU process restarts runs with 0 for up to 30 s.
* Bad, because the killed VM stops as if unplugged: instances on os-cmp02 crash, and Nova
  reports them in error.
* Bad, because the values are fixed for today's sizes. Resizing a VM, especially the
  controller, means checking the steps again.

### Confirmation

* The script ran on the laptop against processes in a user scope named like libvirt's.
  * It set 800 and 300 and left alone a process with the same command line outside the slice.
  * A second run printed nothing.
  * An unknown domain gave a warning and exit 1.
* A systemd timer kept starting a service that failed.
* On `insa`: the role's checks pass, a second run reports `changed=0`, and each QEMU process
  has its value. A value reset by hand comes back within 30 s, and `journalctl -u` shows no
  "Started/Finished" line.

### Implementation (2026-11-25)

Run on `insa` in PR #75. Two fixes to the role's own tasks came first; the script and the
units did not change.
* The dry run tried to enable a timer that it had not written. Like the other roles, the
  task is now skipped in check mode until the unit file exists.
* The check counted the line `scopes=6` as a VM. It now keeps only the lines of the VMs in
  the table.

Results:
* The checks passed and a second run reported `changed=0`.
* The six QEMU processes have their values. Their `oom_score` rises in the chosen order:
  router 873, `core` 941, bastion 1009, os-ctl01 1080, os-cmp01 1214, os-cmp02 1346.
* The router's value, set to 0 by hand, was 300 again 35 s later. The journal had the one line
  `router: pid <pid> oom_score_adj 0 -> 300` and no systemd line about the unit, so
  `LogLevelMax=notice` also works with systemd 257.

## More Information

* Runbook: [host-oom-order.md](../runbooks/host-oom-order.md).
* Linux v6.12: https://github.com/torvalds/linux/blob/v6.12/mm/oom_kill.c,
  https://github.com/torvalds/linux/blob/v6.12/fs/proc/base.c.
* `LogLevelMax=`: https://www.freedesktop.org/software/systemd/man/latest/systemd.exec.html.
