#!/bin/bash
# Watches for a utun on the Claude Apps Gateway VPN client CIDR (10.30.x.x)
# and lowers its MTU to 1300 so TLS handshakes to the private gateway don't
# get dropped by OpenVPN encapsulation overhead. Idempotent; safe to run
# every few seconds. Installed as a system LaunchDaemon; runs as root.
set -u
TARGET_MTU=1300
VPN_CIDR_PREFIX="10.30."

for i in $(ifconfig -l); do
  case "$i" in utun*) ;; *) continue ;; esac
  ifconfig "$i" 2>/dev/null | grep -q "inet $VPN_CIDR_PREFIX" || continue
  cur_mtu=$(ifconfig "$i" 2>/dev/null | awk '/mtu/{for(j=1;j<=NF;j++) if($j=="mtu"){print $(j+1); exit}}')
  if [ "$cur_mtu" != "$TARGET_MTU" ]; then
    /sbin/ifconfig "$i" mtu "$TARGET_MTU" && \
      logger -t claude-gw-vpn-mtu "set $i mtu $cur_mtu -> $TARGET_MTU"
  fi
done
