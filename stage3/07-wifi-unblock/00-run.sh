#!/bin/bash -e

install -m 644 files/wifi-unblock.service "${ROOTFS_DIR}/etc/systemd/system/wifi-unblock.service"

on_chroot << EOF
systemctl enable wifi-unblock.service
EOF
