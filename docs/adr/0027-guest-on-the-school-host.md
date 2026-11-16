---
status: accepted
date: 2026-11-16
decision-makers: dhuy21
---

# akasha is a guest on the school host: minimal footprint and reviewed host changes

## Context and Problem Statement

The physical host `insa` is lent by the school. Besides akasha it runs the school's Debian
desktop, a campus NFS mount and possibly management by the school's IT, plus the owner's
powered-off Proxmox VM `linux2024` (ADR-0005). akasha is one tenant of this machine, not its
owner.

Between 2026-11-13 and 2026-11-16, three proposals made during P1 step 4 went further than
akasha's own resources, and the owner caught each of them during review:

* the claim that NetworkManager ignores bridges named `br*` (wrong: its ifupdown plugin skips
  only bridge ports, so the bridges needed an `unmanaged-devices` drop-in);
* a default-deny `input` chain for the whole host, copied from the first host-firewall design
  (lockout risk, and could break the school's NFS mount or IT access);
* `Requires=akasha-firewall.service` on `libvirtd` as a fail-closed guard (it would also stop
  `linux2024` from starting and stop libvirtd whenever the firewall unit stops).

In each case the problem was not the technical detail but the missing question "what does
this touch, who owns it, and what else depends on it?". How should host changes be scoped
and reviewed so that this does not recur?

## Decision Drivers

* The school must not be affected: no change to its services, policies or network access.
* The owner's personal resources (`linux2024`) must keep working as before.
* Mistakes on `insa` are expensive: the only access is remote (Tailscale), and the owner must
  travel to the machine to recover it.
* Claude has no direct access to the host; review happens on the plan and the code.

## Considered Options

* Guest principle + a fixed plan template with a blast-radius table + independent review of
  risky steps
* Treat `insa` as a dedicated akasha host (reinstall it for akasha alone): needs the school's
  agreement and removes the school's system; rejected
* Status quo (case-by-case judgement): it produced the three proposals above

## Decision Outcome

Chosen option: "Guest principle + plan template + independent review".

### What akasha owns on `insa`

* the nftables table `inet akasha` and units named `akasha-*`;
* files whose name contains `akasha` (`/etc/network/interfaces.d/akasha-bridges`,
  `/etc/sysctl.d/90-akasha-network.conf`, `/etc/NetworkManager/conf.d/90-akasha-unmanaged.conf`,
  …) and the Ansible-marked block in `/etc/lvm/lvmlocal.conf`;
* the bridges `br-*`, the LVM volume group `vg_akasha` and `/var/lib/libvirt/akasha`;
* the libvirt domains and volumes created by OpenTofu for the lab.

Host-wide settings already changed with the owner's explicit approval (P1 step 4a):
`net.ipv4.ip_forward = 1` (it was already 1 at runtime), libvirt `firewall_backend =
"nftables"`, and the libvirt `default` network stopped and not autostarted (it stays
defined for `linux2024`).

### Rules

* akasha never changes host-wide policy (firewall default policies, other software's tables
  or units) and never touches what belongs to the school (SSH configuration, NFS mount,
  desktop, users, IT access) or to the owner personally (`linux2024`, libvirtd as a whole).
* Firewall rules match akasha's interfaces (`br-*`) or address ranges only.
* akasha opens no listening service on the uplink `eno1`: services bind to lab or Tailscale
  addresses.
* Any action outside the list above is an explicit decision for the owner, never a default.

### Plan template for every étape

Goal → why → exact actions → **blast radius** → **what can go wrong** → verification →
rollback.

* **Blast radius**: one row per action with the columns *action · touches · owner of it ·
  what else depends on it · effect if it fails · rollback*. A row whose owner is not akasha
  becomes a question to the owner.
* **What can go wrong**: the assumptions not yet verified (tagged INFERRED) and the failure
  modes (fail-open or fail-closed, lockout, effect on other services). A statement about how
  a tool behaves is checked in its documentation or source before it is written as fact.

### Independent review

Plans that change the network, disks, firewall or boot of `insa`, and every irreversible
action, are reviewed by an independent subagent before they are presented. The subagent
reads the plan and the code but not Claude's reasoning or conclusions, and looks for
overreach, wrong assumptions and failure modes. Its findings are shown to the owner with the
plan; the owner still decides.

### Consequences

* Good, because the school's system and `linux2024` stay as they were, and every change
  outside akasha's resources is visible and decided by the owner.
* Good, because recovery stays simple: removing akasha's own objects returns the host to its
  previous state.
* Bad, because plans become longer and risky étapes cost an extra review pass.
* Bad, because akasha does not harden the host against the campus network; that stays the
  school's responsibility.
* The host-firewall design of ADR-0008 (default-deny input) is revised in P1 step 4b.

### Confirmation

Each étape plan on `insa` from step 4b on contains the blast-radius table and the "what can
go wrong" section, and risky plans carry the independent review's findings.
