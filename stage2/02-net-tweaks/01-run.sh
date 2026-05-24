#!/bin/bash -e

# Newer versions of raspberrypi-sys-mods set rfkill.default_state=0 to prevent
# radiating on 5GHz bands until the WLAN regulatory domain is set.
# Unfortunately, this also blocks bluetooth, so we whitelist the known
# on-board BT adapters here.

mkdir -p "${ROOTFS_DIR}/var/lib/systemd/rfkill/"
#           5                 miniuart 4      miniuart Zero   miniuart other  other
for addr in 107d50c000.serial 3f215040.serial 20215040.serial fe215040.serial soc; do
	echo 0 > "${ROOTFS_DIR}/var/lib/systemd/rfkill/platform-${addr}:bluetooth"
done

# Enable WiFi by default
on_chroot << EOF
# Unblock WiFi hardware (ignore errors in chroot)
rfkill unblock wifi 2>/dev/null || true

# Enable WiFi services
systemctl enable wpa_supplicant || true
systemctl enable NetworkManager || true

# Set WiFi regulatory domain if specified
if [ -v WPA_COUNTRY ]; then
	SUDO_USER="${FIRST_USER_NAME}" raspi-config nonint do_wifi_country "${WPA_COUNTRY}" || true
else
	# Set default regulatory domain to US (ignore errors in chroot)
	iw reg set US 2>/dev/null || true
fi
EOF

if [ -v WPA_COUNTRY ]; then
	on_chroot <<- EOF
		SUDO_USER="${FIRST_USER_NAME}" raspi-config nonint do_wifi_country "${WPA_COUNTRY}"
	EOF
elif [ -d "${ROOTFS_DIR}/var/lib/NetworkManager" ]; then
	# Enable WiFi in NetworkManager (changed from WirelessEnabled=false)
	cat > "${ROOTFS_DIR}/var/lib/NetworkManager/NetworkManager.state" <<- EOF
		[main]
		WirelessEnabled=true
	EOF
fi

# Add network priority and DNS configuration
cat >> "${ROOTFS_DIR}/etc/NetworkManager/NetworkManager.conf" << 'EOF'

[main]
dns=systemd-resolved

[connection-ethernet]
ipv4.route-metric=100
ipv4.dns=8.8.8.8,192.168.1.1

[connection-wifi]
ipv4.route-metric=600
ipv4.dns=8.8.8.8,192.168.1.1

[connection-cellular]
ipv4.route-metric=800
ipv4.dns=8.8.8.8,8.8.4.4
EOF

# Configure systemd-resolved with reliable DNS servers
mkdir -p "${ROOTFS_DIR}/etc/systemd/resolved.conf.d"
cat > "${ROOTFS_DIR}/etc/systemd/resolved.conf.d/dns.conf" << 'EOF'
[Resolve]
DNS=8.8.8.8 8.8.4.4
FallbackDNS=1.1.1.1 1.0.0.1
DNSSEC=allow-downgrade
Cache=yes
EOF

# Enable systemd-resolved (check if it exists first)
on_chroot << 'EOF'
if systemctl list-unit-files | grep -q "systemd-resolved.service"; then
    systemctl enable systemd-resolved || true
else
    echo "systemd-resolved.service not found, skipping..."
fi
EOF
