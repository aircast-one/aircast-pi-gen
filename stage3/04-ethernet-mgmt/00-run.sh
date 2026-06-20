#!/bin/bash -e

# eth0 management/uplink, headless either way:
#   - ethernet-dhcp:   tried first; uses DHCP when wired to a router/switch
#                      (and provides a fallback uplink below cellular).
#   - ethernet-static: only activates when DHCP fails (direct laptop<->Pi cable),
#                      pinning a fixed 192.168.2.6 so the Pi is still reachable.
# Applies to any wired interface. No-ops on boards without an Ethernet port
# (e.g. Pi Zero 2 W): neither profile activates.
install -D -m 600 files/ethernet.nmconnection "${ROOTFS_DIR}/etc/NetworkManager/system-connections/ethernet.nmconnection"
install -D -m 600 files/ethernet-static.nmconnection "${ROOTFS_DIR}/etc/NetworkManager/system-connections/ethernet-static.nmconnection"
