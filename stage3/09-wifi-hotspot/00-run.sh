#!/bin/bash -e

# Recovery hotspot: when no known Wi-Fi client network connects, NetworkManager
# falls back (autoconnect-priority=-10) to broadcasting an AP so the device is
# always reachable. SSID tracks the hostname; passphrase is "raspberry".
install -D -m 600 files/hotspot.nmconnection "${ROOTFS_DIR}/etc/NetworkManager/system-connections/hotspot.nmconnection"

install -m 755 files/aircast-hotspot-ssid.sh "${ROOTFS_DIR}/usr/local/bin/aircast-hotspot-ssid.sh"
install -m 644 files/aircast-hotspot-ssid.service "${ROOTFS_DIR}/etc/systemd/system/aircast-hotspot-ssid.service"

# stage2/02-net-tweaks ships Wi-Fi disabled (WirelessEnabled=false) when no
# WPA_COUNTRY is set. The AP needs the radio on, so enable it here.
mkdir -p "${ROOTFS_DIR}/var/lib/NetworkManager"
cat > "${ROOTFS_DIR}/var/lib/NetworkManager/NetworkManager.state" <<- EOF
	[main]
	WirelessEnabled=true
EOF

on_chroot << EOF
systemctl enable aircast-hotspot-ssid.service
EOF
