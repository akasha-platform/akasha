#!/bin/bash
# Read-only state of insa around a reboot (runbook host-reboot.md, open question A17). Copied to
# insa, then run as root with the terminal on stdin (sudo asks for its password):
#   ssh insa 'cat > /tmp/akasha-state.sh' < infra/scripts/insa-state.sh
#   ssh -t -o LogLevel=error insa 'sudo bash /tmp/akasha-state.sh' | tr -d '\r' > <file>
# Prints one line per item, in a fixed order and in the C locale (insa's is French), so that the
# files from before and after a reboot compare with diff. Prints no Tailscale or campus address.
set -u
export LC_ALL=C
v() { virsh -c qemu:///system "$@" 2>/dev/null; }

echo "boot_id=$(cat /proc/sys/kernel/random/boot_id)"
echo "kernel=$(uname -r)"
echo "reboot_required=$([ -e /var/run/reboot-required ] && echo yes || echo no)"
echo "login_sessions=$(loginctl list-sessions --no-legend 2>/dev/null | wc -l)"
for b in br-transit br-mgmt br-tun br-ext; do
  if [ -d "/sys/class/net/$b" ]; then
    echo "bridge $b present" \
      "ipv6_disabled=$(cat "/proc/sys/net/ipv6/conf/$b/disable_ipv6")" \
      "forwarding=$(cat "/proc/sys/net/ipv4/conf/$b/forwarding")" \
      "networkmanager=$(nmcli -g GENERAL.STATE device show "$b" 2>/dev/null | cut -d' ' -f2- | tr -d '()')"
  else
    echo "bridge $b MISSING"
  fi
done
echo "ip_forward=$(cat /proc/sys/net/ipv4/ip_forward)"
echo "libvirt_default_network_active=$(v net-info default | awk '/^Active/ {print $2}')"
echo "akasha_firewall=$(systemctl is-active akasha-firewall) $(systemctl is-enabled akasha-firewall)"
echo "nft_table_inet_akasha=$(nft list tables | grep -c '^table inet akasha$')"
echo "guard_rule=$(nft list chain inet akasha forward 2>/dev/null | grep -c 'oifname != "br-transit"')"
for n in 10.10.0.0/24 10.20.0.0/24 10.255.255.0/29; do
  # `linkdown` only says no VM is attached yet.
  echo "route $n: $(ip route show exact "$n" | sed 's/ proto .*//; s/ linkdown//; s/ *$//')"
done
echo "tailscaled=$(systemctl is-active tailscaled) $(systemctl is-enabled tailscaled)"
echo "tailscale_advertised=$(tailscale debug prefs 2>/dev/null \
  | python3 -c 'import json, sys; print(sorted(json.load(sys.stdin).get("AdvertiseRoutes") or []))' 2>/dev/null)"
echo "tailscaled_iptables_mode_logged=$(journalctl -b -u tailscaled --no-pager 2>/dev/null | grep -q 'default choosing iptables' && echo yes || echo no)"
echo "images_mount=$(findmnt -no FSTYPE /var/lib/libvirt/akasha)"
echo "pool_akasha=$(v pool-info akasha | awk '/^State/ {print $2}')"
echo "libvirt_guests=$(systemctl is-enabled libvirt-guests 2>/dev/null)" \
  "$(grep -E '^(ON_BOOT|ON_SHUTDOWN)=' /etc/default/libvirt-guests 2>/dev/null | tr '\n' ' ')"
# Unit files, not runtime states: a timer's oneshot service may be running at that very moment.
systemctl list-unit-files 'akasha-*' --no-legend --plain | awk '{print "unit", $1, $2}'
for t in $(systemctl list-unit-files 'akasha-*.timer' --no-legend --plain | awk '{print $1}'); do
  echo "timer $t $(systemctl is-active "$t")"
done
v list --all --name | grep . | sort | while read -r d; do
  echo "vm $d autostart=$(v dominfo "$d" | awk '/^Autostart/ {print $2}')" \
    "managed_save=$(v dominfo "$d" | awk '/^Managed save/ {print $3}')"
done
