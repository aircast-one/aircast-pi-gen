#!/bin/bash -e

install -D -m 600 files/hotspot.nmconnection "${ROOTFS_DIR}/etc/NetworkManager/system-connections/hotspot.nmconnection"

install -m 755 files/aircast-hotspot-ssid.sh "${ROOTFS_DIR}/usr/local/bin/aircast-hotspot-ssid.sh"
install -m 644 files/aircast-hotspot-ssid.service "${ROOTFS_DIR}/etc/systemd/system/aircast-hotspot-ssid.service"

on_chroot << EOF
systemctl enable aircast-hotspot-ssid.service
EOF
