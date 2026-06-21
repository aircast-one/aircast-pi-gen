#!/bin/bash -e

# Per-device hostname (aircast-<serial>) assigned on first boot, so the recovery
# hotspot SSID and Tailscale identity are unique per unit. stage1 still bakes the
# generic "aircast" as the default; this overrides it once on first boot.
install -m 755 files/aircast-set-hostname.sh "${ROOTFS_DIR}/usr/local/bin/aircast-set-hostname.sh"
install -m 644 files/aircast-set-hostname.service "${ROOTFS_DIR}/etc/systemd/system/aircast-set-hostname.service"

on_chroot << EOF
systemctl enable aircast-set-hostname.service
EOF
