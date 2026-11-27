#!/bin/bash
# Read-only state of insa around a reboot (runbook host-reboot.md, open question A17). Run as
# root through SSH, from the repository on the laptop:
#   ssh -t insa 'sudo bash -s' < infra/scripts/insa-state.sh | tee ~/akasha-private/reboot/<when>.txt
# Prints one line per checked item, in a fixed order, so that the files from before and after a
# reboot can be compared with diff. Prints no Tailscale address and no campus address.
set -u
v() { virsh -c qemu:///system "$@" 2>/dev/null; }

echo "kernel=$(uname -r)"
echo "reboot_required=$([ -e /var/run/reboot-required ] && echo yes || echo no)"
for b in br-transit br-mgmt br-tun br-ext; do
  if [ -d "/sys/class/net/$b" ]; then
    echo "bridge $b up=$(cat "/sys/class/net/$b/operstate")" \
      "ipv6_disabled=$(cat "/proc/sys/net/ipv6/conf/$b/disable_ipv6")" \
      "forwarding=$(cat "/proc/sys/net/ipv4/conf/$b/forwarding")" \
      "networkmanager=$(nmcli -g GENERAL.STATE device show "$b" 2>/dev/null | cut -d' ' -f2- | tr -d '()')"
  else
    echo "bridge $b MISSING"
  fi
done
echo "ip_forward=$(cat /proc/sys/net/ipv4/ip_forward)"
echo "libvirt_default_network_active=$(v net-info default | awk '/^Active/ {print $2}')"
echo "akasha_firewall=$(systemctl is-active akasha-firewall)"
echo "nft_table_inet_akasha=$(nft list tables | grep -c '^table inet akasha$')"
echo "guard_rule=$(nft list chain inet akasha forward 2>/dev/null | grep -c 'oifname != "br-transit"')"
for n in 10.10.0.0/24 10.20.0.0/24 10.255.255.0/29; do
  echo "route $n: $(ip route show exact "$n" | sed 's/ proto .*//; s/ *$//')"
done
echo "tailscaled=$(systemctl is-active tailscaled)"
echo "tailscale_advertised=$(tailscale debug prefs 2>/dev/null \
  | python3 -c 'import json, sys; print(sorted(json.load(sys.stdin).get("AdvertiseRoutes") or []))')"
echo "tailscaled_chose_iptables=$(journalctl -b -u tailscaled --no-pager 2>/dev/null | grep -c 'default choosing iptables')"
echo "images_mount=$(findmnt -no FSTYPE /var/lib/libvirt/akasha)"
echo "pool_akasha=$(v pool-info akasha | awk '/^State/ {print $2}')"
systemctl list-units 'akasha-*' --all --no-legend --plain | awk '{print "unit", $1, $3, $4}'
v list --all --name | grep . | sort | while read -r d; do
  echo "vm $d state=$(v domstate "$d" | tr ' ' '_') autostart=$(v dominfo "$d" | awk '/^Autostart/ {print $2}')"
done
