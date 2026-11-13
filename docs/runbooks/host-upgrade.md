# Host upgrade and reboot (`insa`)

The host is reached only through Tailscale, which is itself upgraded by `apt`. Run the upgrade
so that it survives the SSH session dropping, and reboot only when someone can reach the
machine room the same day (old kernels stay selectable in GRUB, but only from the console).

## Before

```bash
ssh -t insa 'uname -r; cat /etc/debian_version; systemctl --failed --no-legend;
  sudo virsh list --all --autostart;
  LC_ALL=C apt-get --simulate full-upgrade | grep -E "^(Inst|Remv)"'
```

Review removals (`Remv`) and sensitive packages: kernel, tailscale, lvm2, systemd, grub,
libvirt, qemu. No lab VM may be running.

## Upgrade (survives a dropped SSH session)

```bash
ssh -t insa 'sudo systemd-run --unit=akasha-upgrade -p RemainAfterExit=yes \
  --setenv=DEBIAN_FRONTEND=noninteractive \
  apt-get -y -o Dpkg::Options::=--force-confold -o Dpkg::Options::=--force-confdef full-upgrade'
ssh -t insa 'sudo journalctl -u akasha-upgrade -f'     # Ctrl-C when apt has finished
```

`--force-confold` keeps locally modified configuration files (for example
`/etc/lvm/lvmlocal.conf`, managed by Ansible). Then check: `systemctl status akasha-upgrade`
shows `status=0/SUCCESS`, `sudo dpkg --audit` prints nothing, no package is left to upgrade.

## Reboot

```bash
ssh -t insa 'sudo systemctl reboot'
until ssh -o ConnectTimeout=5 -o BatchMode=yes insa true 2>/dev/null; do sleep 10; done
```

If the host is not back within about 10 minutes, go to the console: pick the previous kernel
in GRUB ("Advanced options"), then read `journalctl -b -1 -p err`.

## After

```bash
ssh -t insa 'uname -r; cat /etc/debian_version; systemctl --failed --no-legend;
  sudo pvs -a; sudo lvs; findmnt /var/lib/libvirt/akasha;
  systemctl is-active tailscaled libvirtd var-lib-libvirt-akasha.mount;
  sudo journalctl -b -p err --no-pager | tail -20'
cd infra/ansible && uv run ansible-playbook playbooks/host.yml -K   # expect changed=0
```

## Stale package lists

- **Symptom:** `apt` installs a version that the mirror no longer has (HTTP 404), or the host
  stays on an old point release although `apt-get update` reports `Hit` for `trixie`.
- **Cause (seen 2026-11-13):** `InRelease` was refreshed but the `Packages` files were not
  (they dated from the previous point release); apt keeps using them while `InRelease` does not
  change.
- **Diagnosis:** `ls -l --time-style=long-iso /var/lib/apt/lists/ | grep trixie_` — the
  `Packages` files are older than `InRelease`.
- **Fix:** `sudo rm /var/lib/apt/lists/deb.debian.org_debian_dists_trixie_*` then
  `sudo apt-get update` (the files are a cache; `trixie_` does not match `trixie-updates`).
