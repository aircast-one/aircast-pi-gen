#!/bin/bash -e

install -m 644 files/99-aircast-mm-ignore-fc.rules "${ROOTFS_DIR}/etc/udev/rules.d/"
install -D -m 600 files/cellular.nmconnection "${ROOTFS_DIR}/etc/NetworkManager/system-connections/cellular.nmconnection"

install -d "${ROOTFS_DIR}/etc/systemd/system/ModemManager.service.d"
install -m 644 files/modemmanager-strict.conf "${ROOTFS_DIR}/etc/systemd/system/ModemManager.service.d/filter-policy.conf"

on_chroot << EOF
systemctl enable ModemManager.service
EOF
